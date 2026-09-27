-- ============================================================================
-- invalid_inserts_test.sql
-- Proof script for docs/05-schema-proof.md.
-- Run against a database that already has 001_init_schema.sql applied.
--
--   psql -f db/migrations/001_init_schema.sql your_db
--   psql -f db/proof/invalid_inserts_test.sql your_db
--
-- Each numbered block is expected to raise an error. \set ON_ERROR_STOP off
-- lets the script keep going so you can see all three failures in one run.
-- ============================================================================

\set ON_ERROR_STOP off

-- ----------------------------------------------------------------------------
-- Fixture data: one farmer, one buyer, one supply listing, one order.
-- ----------------------------------------------------------------------------
INSERT INTO app_user (id, name, email, phone, role)
VALUES ('11111111-1111-1111-1111-111111111111', 'Amina Yusuf', 'amina@example.com', '+2348000000001', 'farmer');

INSERT INTO farmer (id, "userId", location)
VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'Kaduna');

INSERT INTO buyer (id, name, "contactEmail")
VALUES ('33333333-3333-3333-3333-333333333333', 'GreenMart Foods', 'procurement@greenmart.example');

-- A supply listing with 500 kg of tomatoes available.
INSERT INTO supply (id, "farmerId", produce, quantity, unit, "availableDate")
VALUES ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'tomato', 500, 'kg', '2026-10-01');

-- An order for 1000 kg of tomatoes.
INSERT INTO "order" (id, "buyerId", produce, "requiredQuantity", unit, "requiredDate", "deliveryLocation")
VALUES ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', 'tomato', 1000, 'kg', '2026-10-05', 'Abuja');

-- ----------------------------------------------------------------------------
-- TEST 1: Supply with a farmerId that does not exist -> FK violation
-- ----------------------------------------------------------------------------
\echo '--- TEST 1: Supply row referencing a nonexistent farmer (expect FK violation) ---'
INSERT INTO supply (id, "farmerId", produce, quantity, unit, "availableDate")
VALUES ('66666666-6666-6666-6666-666666666666', '99999999-9999-9999-9999-999999999999', 'maize', 200, 'kg', '2026-10-01');

-- ----------------------------------------------------------------------------
-- TEST 2: SupplyAllocation with a negative quantity -> check constraint
-- ----------------------------------------------------------------------------
\echo '--- TEST 2: Allocation with quantity = -500 (expect check_violation) ---'
INSERT INTO supply_allocation (id, "supplyId", "orderId", quantity, "farmerNameSnapshot", "idempotencyKey")
VALUES ('77777777-7777-7777-7777-777777777777', '44444444-4444-4444-4444-444444444444',
        '55555555-5555-5555-5555-555555555555', -500, 'Amina Yusuf', 'idem-test-negative');

-- ----------------------------------------------------------------------------
-- TEST 3: Allocation exceeding the supply listing's remaining quantity
-- The listing only has 500 kg; requesting 800 kg must be rejected by the
-- allocation-sum trigger (trg_check_allocation_within_supply).
-- ----------------------------------------------------------------------------
\echo '--- TEST 3: Allocate 800kg against a 500kg listing (expect ALLOCATION_EXCEEDS_SUPPLY) ---'
INSERT INTO supply_allocation (id, "supplyId", "orderId", quantity, "farmerNameSnapshot", "idempotencyKey")
VALUES ('88888888-8888-8888-8888-888888888888', '44444444-4444-4444-4444-444444444444',
        '55555555-5555-5555-5555-555555555555', 800, 'Amina Yusuf', 'idem-test-overallocate');

-- ----------------------------------------------------------------------------
-- CONTROL CASE: a valid allocation of 300kg should succeed, and should be
-- reflected in Order.fulfilledQuantity / status and Supply.status.
-- ----------------------------------------------------------------------------
\set ON_ERROR_STOP on
\echo '--- CONTROL: valid allocation of 300kg (expect success) ---'
INSERT INTO supply_allocation (id, "supplyId", "orderId", quantity, "farmerNameSnapshot", "idempotencyKey")
VALUES ('99999999-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '44444444-4444-4444-4444-444444444444',
        '55555555-5555-5555-5555-555555555555', 300, 'Amina Yusuf', 'idem-test-valid-1');

\echo '--- Resulting order state (expect fulfilledQuantity=300, status=partially_fulfilled) ---'
SELECT id, "requiredQuantity", "fulfilledQuantity", status FROM "order" WHERE id = '55555555-5555-5555-5555-555555555555';

\echo '--- Resulting supply state (expect status=partially_allocated) ---'
SELECT id, quantity, status FROM supply WHERE id = '44444444-4444-4444-4444-444444444444';

\echo '--- CONTROL: repeating the same idempotencyKey must not double-allocate (expect unique_violation) ---'
\set ON_ERROR_STOP off
INSERT INTO supply_allocation (id, "supplyId", "orderId", quantity, "farmerNameSnapshot", "idempotencyKey")
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '44444444-4444-4444-4444-444444444444',
        '55555555-5555-5555-5555-555555555555', 300, 'Amina Yusuf', 'idem-test-valid-1');
