# 5. Schema Proof Plan

## Migration to implement

All tables from `02-data-model.md`, with:
- the constraints from `04-design-decisions.md §4.6` (FKs, check
  constraints on `quantity`/`requiredQuantity`/`fulfilledQuantity`, unique
  constraint on `SupplyAllocation.idempotencyKey`, the trigger-backed
  allocation-sum-vs-supply-quantity check),
- the check constraints backing the Order and Supply state machines from
  `§4.3`, and
- the indexes from `§4.7`.

Runnable version: [`db/migrations/001_init_schema.sql`](../db/migrations/001_init_schema.sql).

## The 5 queries answering the 5 key actions

1. `INSERT INTO "order" (...) VALUES (...) RETURNING *` — validated against
   `buyer.id` existing first **[Action 1]**
2. `INSERT INTO supply (...) VALUES (...) RETURNING *` /
   `UPDATE supply SET quantity = ? WHERE id = ?` **[Action 2]**
3. `SELECT * FROM supply WHERE produce = ? AND status = 'available' ORDER BY "availableDate" ASC LIMIT ? OFFSET ?` **[Action 3]**
4. `INSERT INTO supply_allocation (...) ON CONFLICT ("idempotencyKey") DO NOTHING RETURNING *`,
   followed by `UPDATE "order" SET "fulfilledQuantity" = "fulfilledQuantity" + ? WHERE id = ?`
   in the same transaction **[Action 4]**
5. `SELECT "requiredQuantity", "fulfilledQuantity", status FROM "order" WHERE id = ?` **[Action 5]**

Query plans would be checked on #3 (the produce/status lookup, heaviest due
to scanning all available supply listings across farmers) and the buyer
order-history list query, confirming the indexes from `§4.7` are used
rather than a sequential scan (`EXPLAIN ANALYZE` should show an Index Scan,
not a Seq Scan, on `supply` and on `order`).

## Three invalid inserts to prove constraints work

1. Insert a `supply` row with a `farmerId` that does not exist in the
   `farmer` table → should be rejected by the foreign key constraint.
2. Insert a `supply_allocation` with `quantity = -500` → should be rejected
   by the check constraint.
3. Insert a `supply_allocation` whose `quantity`, added to the sum of
   existing allocations against the same `supplyId`, exceeds that supply
   listing's `quantity` (e.g. allocate 800 kg against a listing that only
   has 500 kg of unallocated quantity remaining) → should be rejected by
   the allocation-sum trigger.

Runnable version: [`db/proof/invalid_inserts_test.sql`](../db/proof/invalid_inserts_test.sql).
Each statement is expected to raise an error; the script prints which
constraint fired for each one.

## Defense readiness checklist

- **One denormalized fact and its justification:** `Order.fulfilledQuantity`
  — maintained as a rolling total updated on every allocation write, rather
  than recomputed via `SUM(SupplyAllocation.quantity)` on every read,
  because fulfillment tracking is the highest-traffic read in the product
  and a completed/cancelled order's fulfillment figure is a settled fact
  that shouldn't require re-aggregating history to display.
- **Constraint preventing an invalid over-allocation:** the trigger-backed
  check that `SUM(SupplyAllocation.quantity) WHERE supplyId = ?` can never
  exceed `Supply.quantity`, applied before every allocation insert.
- **Why the order stores `fulfilledQuantity` rather than computing it
  live:** the same reasoning as the denormalization above — it's read far
  more often than it's written, and recomputing it live from allocation
  history on every order-detail request doesn't scale the way a maintained
  rolling total does.
- **Concrete GraphQL trigger point:** when a second client type (e.g. a
  farmer-facing app or a future buyer portal) needs a materially different
  field set from the same entities, or when a single screen requires
  composing 3+ REST calls (order + buyer + allocations + each allocation's
  farmer) into one view.
