# 3. API Design

All paths versioned under `/api/v1/`.

## [Action 1] Create a buyer order

`POST /api/v1/orders`
- Request body: `{ buyerId, produce, requiredQuantity, unit, requiredDate, deliveryLocation }` — all required
- Response: `201` — `{ id, status: "pending", buyerId, produce, requiredQuantity, fulfilledQuantity: 0, unit, requiredDate, deliveryLocation, createdAt }`
- Errors: `422` missing/invalid fields (e.g. `requiredQuantity <= 0`); `404` buyer not found
- Idempotency: accepts an optional `Idempotency-Key` header so a client retry after a network timeout doesn't create two orders

## [Action 2] Add or update farmer supply

`POST /api/v1/supplies`
- Request body: `{ farmerId, produce, quantity, unit, availableDate }` — all required
- Response: `201` — created Supply with `status: "available"`
- Errors: `422` invalid fields; `404` farmer not found

`PATCH /api/v1/supplies/:id`
- Request body: `{ quantity? }` — at least one updatable field
- Response: `200` — updated Supply
- Errors: `404` not found; `409` new `quantity` is lower than the sum already allocated against this listing (a farmer cannot retroactively shrink supply below what's already been promised to buyers); `422` invalid quantity
- Idempotency: naturally idempotent — repeating the same PATCH body produces the same resulting state

## [Action 3] View available supply

`GET /api/v1/supplies`
- Query params: `produce` (filter), `status` (filter, default `available`), `limit` (default 20, max 100), `offset` (default 0), `sort` (`availableDate` or `createdAt`, default `availableDate`), `order` (`asc`/`desc`, default `asc`)
- Response: `200` — `{ data: [...], meta: { limit, offset, total } }`
- Errors: `400` unknown `status`/`sort` value; `400` `limit`/`offset` non-numeric (an oversized `limit` is clamped to 100, not rejected)

## [Action 4] Allocate supply to a buyer order

`POST /api/v1/orders/:id/allocations`
- Request body: `{ supplyId, quantity, idempotencyKey }` — all required
- Response: `201` — `{ id, orderId, supplyId, quantity, farmerNameSnapshot, createdAt }`
- Errors:
  - `404` order or supply not found
  - `422` order is not in `pending` or `partially_fulfilled` state
  - `422` quantity would over-fulfill the order (`fulfilledQuantity + quantity > requiredQuantity`)
  - `409` quantity would exceed the supply listing's remaining (unallocated) amount
- Idempotency: enforced via the required `idempotencyKey`, unique at the database level — a duplicate submission (e.g. a double-click) returns the existing allocation, never creates a second one and never double-counts toward `fulfilledQuantity`

## [Action 5] Track order fulfillment

`GET /api/v1/orders/:id`
- Response: `200` — `{ id, buyerId, produce, requiredQuantity, fulfilledQuantity, remainingQuantity, unit, status, requiredDate, deliveryLocation, createdAt, updatedAt }`
  (`remainingQuantity` is computed as `requiredQuantity - fulfilledQuantity` at response time, not stored)
- Errors: `404` not found

`GET /api/v1/orders/:id/allocations`
- Response: `200` — list of SupplyAllocation rows for the order, each including `farmerNameSnapshot`
- Errors: `404` order not found

## Entity CRUD (representative — Order list shown as the pagination example)

`GET /api/v1/orders`
- Query params: `limit` (default 20, max 100), `offset` (default 0), `status` (filter), `buyerId` (filter), `sort` (`createdAt`, default `desc`)
- Response: `200` — `{ data: [...], meta: { limit, offset, total } }`
- Errors: `400` invalid `status`; `400` `limit`/`offset` non-numeric (clamped rather than errored if simply too large)

`GET /api/v1/farmers/:id`, `GET /api/v1/buyers/:id` follow the same
item-endpoint pattern with `404` on miss.

## Error envelope (applies to all endpoints above)

```json
{ "error": { "code": "ALLOCATION_EXCEEDS_SUPPLY", "message": "This allocation would exceed the supply listing's remaining quantity" } }
```

## Over-fetching: REST vs. GraphQL

Endpoint: `GET /api/v1/orders/:id`

A typical REST response for an order detail view returns the full row,
including fields a fulfillment-tracking dashboard never displays:

```json
{
  "id": "b6b1...", "buyerId": "a11c...", "produce": "tomato",
  "requiredQuantity": 5000, "fulfilledQuantity": 4500,
  "unit": "kg", "status": "partially_fulfilled",
  "requiredDate": "2026-10-02", "deliveryLocation": "Abuja",
  "createdAt": "...", "updatedAt": "...", "cancelledAt": null
}
```

The fulfillment-tracking screen only needs `requiredQuantity`,
`fulfilledQuantity`, `remainingQuantity`, and `status`. The equivalent
GraphQL query:

```graphql
query {
  order(id: "b6b1...") {
    requiredQuantity
    fulfilledQuantity
    remainingQuantity
    status
  }
}
```

This returns only the four requested fields instead of the full row.

**Position:** REST is fine for this MVP — the payload is small (a handful
of scalar fields, no nested collections unless allocations are explicitly
requested via the separate `/allocations` endpoint), and the aggregator's
dashboard can simply ignore unused fields with negligible bandwidth cost.
Switch to GraphQL only once (a) multiple client types (aggregator
dashboard, farmer app, a future buyer-facing portal, a partner integration)
each need meaningfully different shapes of the same underlying entities, or
(b) a single screen needs to compose data from 3+ REST calls (e.g. order +
buyer + all allocations + each allocation's farmer) into one view — at that
point GraphQL's field selection and single round-trip both start paying for
their added complexity.

## Real-time updates: SSE vs. WebSockets

Use case: an aggregator viewing an order's fulfillment progress while
another aggregator (or the same one, on another device) allocates supply
against it, or while a farmer updates their remaining supply quantity.

This is one-directional from the server's perspective at any given
moment — the viewing client only needs to *receive* updated
fulfillment/quantity figures; it doesn't need to send data back over the
same channel in real time. **Server-Sent Events** fit this better than
WebSockets: SSE is simpler to implement and operate (plain HTTP, automatic
reconnection built into the browser `EventSource` API), and the lack of
bidirectionality means we're not paying for WebSocket's full-duplex
complexity for a feature that only pushes in one direction. WebSockets
would be justified instead if the same channel needed to carry two-way
traffic — for example, an in-app negotiation/chat between an aggregator and
a farmer over an allocation — at which point a single bidirectional channel
becomes simpler than running SSE and a separate write path side by side.
