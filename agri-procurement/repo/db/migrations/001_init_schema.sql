-- ============================================================================
-- 001_init_schema.sql
-- Agricultural Procurement & Supply Coordination Platform
-- Implements the entity model from docs/02-data-model.md and the
-- constraints/state-machine rules from docs/04-design-decisions.md.
-- Target: PostgreSQL 14+
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- USER
-- ----------------------------------------------------------------------------
CREATE TABLE app_user (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE,
    phone        TEXT NOT NULL,
    role         TEXT NOT NULL CHECK (role IN ('aggregator', 'farmer')),
    "createdAt"  TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updatedAt"  TIMESTAMPTZ NOT NULL DEFAULT now(),
    "deletedAt"  TIMESTAMPTZ
);

-- ----------------------------------------------------------------------------
-- FARMER  (1:1 with a farmer-role User)
-- ----------------------------------------------------------------------------
CREATE TABLE farmer (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "userId"     UUID NOT NULL UNIQUE REFERENCES app_user(id),
    location     TEXT NOT NULL,
    "createdAt"  TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updatedAt"  TIMESTAMPTZ NOT NULL DEFAULT now(),
    "deletedAt"  TIMESTAMPTZ
);

-- ----------------------------------------------------------------------------
-- BUYER
-- ----------------------------------------------------------------------------
CREATE TABLE buyer (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name           TEXT NOT NULL,
    "contactEmail" TEXT,
    "contactPhone" TEXT,
    "createdAt"    TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updatedAt"    TIMESTAMPTZ NOT NULL DEFAULT now(),
    "deletedAt"    TIMESTAMPTZ
);

-- ----------------------------------------------------------------------------
-- SUPPLY
-- ----------------------------------------------------------------------------
CREATE TABLE supply (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "farmerId"      UUID NOT NULL REFERENCES farmer(id),
    produce         TEXT NOT NULL,
    quantity        NUMERIC(14, 3) NOT NULL CHECK (quantity >= 0),
    unit            TEXT NOT NULL CHECK (unit IN ('kg', 'ton', 'bag', 'crate')),
    "availableDate" DATE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'available'
                        CHECK (status IN ('available', 'partially_allocated', 'fully_allocated', 'withdrawn')),
    "createdAt"     TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updatedAt"     TIMESTAMPTZ NOT NULL DEFAULT now(),
    "deletedAt"     TIMESTAMPTZ
);

-- [Action 2] find a farmer's own listings
CREATE INDEX idx_supply_farmer_status ON supply ("farmerId", status);
-- [Action 3] find available supply by produce type
CREATE INDEX idx_supply_produce_status ON supply (produce, status);

-- ----------------------------------------------------------------------------
-- ORDER  ("order" is a reserved word -> quoted throughout)
-- ----------------------------------------------------------------------------
CREATE TABLE "order" (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "buyerId"           UUID NOT NULL REFERENCES buyer(id),
    produce             TEXT NOT NULL,
    "requiredQuantity"  NUMERIC(14, 3) NOT NULL CHECK ("requiredQuantity" > 0),
    "fulfilledQuantity" NUMERIC(14, 3) NOT NULL DEFAULT 0,
    unit                TEXT NOT NULL CHECK (unit IN ('kg', 'ton', 'bag', 'crate')),
    "requiredDate"      DATE NOT NULL,
    "deliveryLocation"  TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'partially_fulfilled', 'fully_fulfilled', 'completed', 'cancelled')),
    "createdAt"         TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updatedAt"         TIMESTAMPTZ NOT NULL DEFAULT now(),
    "cancelledAt"       TIMESTAMPTZ,

    -- an order can never be recorded as over-fulfilled
    CONSTRAINT chk_order_not_overfulfilled CHECK ("fulfilledQuantity" <= "requiredQuantity"),
    -- a cancelled order's timestamp and status can't disagree
    CONSTRAINT chk_order_cancelledat_matches_status CHECK (
        ("cancelledAt" IS NULL AND status <> 'cancelled') OR
        ("cancelledAt" IS NOT NULL AND status = 'cancelled')
    )
);

-- [Action 5] find allocations for a given order / paginate an order list
CREATE INDEX idx_order_buyer_created ON "order" ("buyerId", "createdAt" DESC);

-- ----------------------------------------------------------------------------
-- SUPPLY_ALLOCATION  (the many-to-many join between Supply and Order)
-- ----------------------------------------------------------------------------
CREATE TABLE supply_allocation (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "supplyId"            UUID NOT NULL REFERENCES supply(id),
    "orderId"             UUID NOT NULL REFERENCES "order"(id),
    quantity              NUMERIC(14, 3) NOT NULL CHECK (quantity > 0),
    "farmerNameSnapshot"  TEXT NOT NULL,
    "idempotencyKey"      TEXT NOT NULL UNIQUE,
    "createdAt"           TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updatedAt"           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- [Action 4] sum allocations against a given supply listing
CREATE INDEX idx_allocation_supply ON supply_allocation ("supplyId");
-- [Action 5] find allocations for a given order
CREATE INDEX idx_allocation_order ON supply_allocation ("orderId");

-- ============================================================================
-- TRIGGER: allocation sum can never exceed the supply listing's quantity
-- This is the backstop for the [Action 4] core invariant — enforced in the
-- application layer first, and here so a direct SQL write can't bypass it.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_check_allocation_within_supply()
RETURNS TRIGGER AS $$
DECLARE
    allocated_total NUMERIC(14, 3);
    supply_quantity NUMERIC(14, 3);
BEGIN
    SELECT COALESCE(SUM(quantity), 0)
      INTO allocated_total
      FROM supply_allocation
     WHERE "supplyId" = NEW."supplyId"
       AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

    SELECT quantity INTO supply_quantity FROM supply WHERE id = NEW."supplyId";

    IF allocated_total + NEW.quantity > supply_quantity THEN
        RAISE EXCEPTION
            'ALLOCATION_EXCEEDS_SUPPLY: allocating % against supply % would exceed its remaining quantity (already allocated %, supply has %)',
            NEW.quantity, NEW."supplyId", allocated_total, supply_quantity
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_allocation_within_supply
    BEFORE INSERT OR UPDATE ON supply_allocation
    FOR EACH ROW
    EXECUTE FUNCTION fn_check_allocation_within_supply();

-- ============================================================================
-- TRIGGER: keep Order.fulfilledQuantity and status in sync on allocation
-- writes, and keep Supply.status in sync as it gets allocated against.
-- Implements the denormalized rolling total from docs/04-design-decisions.md §4.1
-- and the state machines from §4.3.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_apply_allocation_effects()
RETURNS TRIGGER AS $$
DECLARE
    order_required   NUMERIC(14, 3);
    order_fulfilled  NUMERIC(14, 3);
    supply_qty       NUMERIC(14, 3);
    supply_allocated NUMERIC(14, 3);
BEGIN
    UPDATE "order"
       SET "fulfilledQuantity" = "fulfilledQuantity" + NEW.quantity,
           "updatedAt" = now()
     WHERE id = NEW."orderId"
    RETURNING "requiredQuantity", "fulfilledQuantity" INTO order_required, order_fulfilled;

    UPDATE "order"
       SET status = CASE
                        WHEN order_fulfilled >= order_required THEN 'fully_fulfilled'
                        ELSE 'partially_fulfilled'
                    END
     WHERE id = NEW."orderId"
       AND status IN ('pending', 'partially_fulfilled');

    SELECT quantity INTO supply_qty FROM supply WHERE id = NEW."supplyId";
    SELECT COALESCE(SUM(quantity), 0) INTO supply_allocated
      FROM supply_allocation WHERE "supplyId" = NEW."supplyId";

    UPDATE supply
       SET status = CASE
                        WHEN supply_allocated >= supply_qty THEN 'fully_allocated'
                        ELSE 'partially_allocated'
                    END,
           "updatedAt" = now()
     WHERE id = NEW."supplyId"
       AND status IN ('available', 'partially_allocated');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_allocation_effects
    AFTER INSERT ON supply_allocation
    FOR EACH ROW
    EXECUTE FUNCTION fn_apply_allocation_effects();
