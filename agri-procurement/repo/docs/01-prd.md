# 1. Product Requirements

## What the product does

A platform that helps agricultural aggregators combine fragmented supply
from many individual farmers to fulfill orders placed by buyers. The system
tracks farmer supply listings, buyer orders, and the allocation of specific
supply quantities against specific orders until an order is fully
fulfilled.

## Who uses it

- **Aggregator** — the primary user. Records buyer orders, views available
  farmer supply, and allocates supply against orders until fulfilled.
- **Farmer** — a secondary user. Lists available produce (quantity, type,
  availability date) for an aggregator to draw on.
- **Buyer** — the party an order is placed on behalf of. Not assumed to
  have direct system access in this version; the aggregator acts on the
  buyer's behalf. Whether buyers get their own login is a later-phase
  decision, out of scope for this MVP.

## The 5 most important user actions

| # | Action | Actor | Why it matters |
|---|--------|-------|-----------------|
| 1 | Create a buyer order | Aggregator | The entry point to the fulfillment workflow — nothing to allocate against without it |
| 2 | Add or update farmer supply | Farmer | The supply side of the marketplace; what an order can eventually be filled from |
| 3 | View available supply | Aggregator | The matching moment — deciding which farmers' produce to draw on for a given order |
| 4 | Allocate supply to a buyer order | Aggregator | The core transaction of the product; must never over-allocate a farmer's supply or over-fulfill an order |
| 5 | Track order fulfillment | Aggregator/Buyer | Answers "how much is left to source" — drives every subsequent allocation decision |

Every entity, constraint, index, and endpoint in this design package is
justified by which of these five actions it serves. Downstream docs
reference them as **[Action 1]** through **[Action 5]**.

## Explicit non-goals for this MVP

- No payment or settlement processing (see `04-design-decisions.md §2`).
- No direct buyer login/portal.
- No multi-currency or pricing fields anywhere in the schema.
