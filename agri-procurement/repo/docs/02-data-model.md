# 2. Entity Model

## Entities

### User — anyone who can log into the system

| Field | Type | Required |
|---|---|---|
| id | UUID | yes |
| name | string | yes |
| email | string, unique | yes |
| phone | string | yes |
| role | enum(aggregator, farmer) | yes |
| createdAt | timestamp | yes |
| updatedAt | timestamp | yes |
| deletedAt | timestamp, nullable | no |

### Farmer — the supply-side profile attached to a `farmer`-role User

| Field | Type | Required |
|---|---|---|
| id | UUID | yes |
| userId | UUID (FK → User), unique | yes |
| location | string | yes |
| createdAt | timestamp | yes |
| updatedAt | timestamp | yes |
| deletedAt | timestamp, nullable | no |

### Buyer — the party an order is placed on behalf of

| Field | Type | Required |
|---|---|---|
| id | UUID | yes |
| name | string | yes |
| contactEmail | string | no |
| contactPhone | string | no |
| createdAt | timestamp | yes |
| updatedAt | timestamp | yes |
| deletedAt | timestamp, nullable | no |

### Supply — a quantity of produce a farmer has made available

| Field | Type | Required |
|---|---|---|
| id | UUID | yes |
| farmerId | UUID (FK → Farmer) | yes |
| produce | string | yes |
| quantity | decimal | yes |
| unit | enum(kg, ton, bag, crate) | yes |
| availableDate | date | yes |
| status | enum(available, partially_allocated, fully_allocated, withdrawn) | yes |
| createdAt | timestamp | yes |
| updatedAt | timestamp | yes |
| deletedAt | timestamp, nullable | no |

### Order — a buyer's request for a quantity of produce

| Field | Type | Required |
|---|---|---|
| id | UUID | yes |
| buyerId | UUID (FK → Buyer) | yes |
| produce | string | yes |
| requiredQuantity | decimal | yes |
| fulfilledQuantity | decimal | yes (defaults to 0 — see `04-design-decisions.md §1`, denormalization #2) |
| unit | enum(kg, ton, bag, crate) | yes |
| requiredDate | date | yes |
| deliveryLocation | string | yes |
| status | enum(pending, partially_fulfilled, fully_fulfilled, completed, cancelled) | yes |
| createdAt | timestamp | yes |
| updatedAt | timestamp | yes |
| cancelledAt | timestamp, nullable | no |

### SupplyAllocation — the join record connecting a Supply listing to an Order, in a specific quantity

This is the entity that makes the Supply ↔ Order relationship
many-to-many.

| Field | Type | Required |
|---|---|---|
| id | UUID | yes |
| supplyId | UUID (FK → Supply) | yes |
| orderId | UUID (FK → Order) | yes |
| quantity | decimal | yes |
| farmerNameSnapshot | string | yes (set at creation — see `04-design-decisions.md §1`, denormalization #1) |
| idempotencyKey | string, unique | yes |
| createdAt | timestamp | yes |
| updatedAt | timestamp | yes |

## Relationships & cardinality

- User **1 : 1** Farmer (only for `farmer`-role users)
- Farmer **1 : many** Supply
- Buyer **1 : many** Order
- Order **1 : many** SupplyAllocation
- Supply **1 : many** SupplyAllocation
- Order **many : many** Supply, *through* SupplyAllocation (one order is
  typically fulfilled from several farmers' supply, and a single supply
  listing may be split across several orders)

## Entity-relationship diagram

![Entity-relationship diagram](diagrams/entity-relationship-diagram.png)

Rendered image files: [`diagrams/entity-relationship-diagram.png`](diagrams/entity-relationship-diagram.png) ·
[`diagrams/entity-relationship-diagram.svg`](diagrams/entity-relationship-diagram.svg) (vector, scales cleanly) ·
source: [`diagrams/entity-relationship-diagram.dot`](diagrams/entity-relationship-diagram.dot) (Graphviz — edit and re-render with `dot -Tpng entity-relationship-diagram.dot -o entity-relationship-diagram.png`).

Mermaid source (renders automatically on GitHub if you prefer this form instead of the static image):

```mermaid
erDiagram
    USER ||--o| FARMER : "is (if role=farmer)"
    FARMER ||--o{ SUPPLY : lists
    BUYER ||--o{ ORDER : places
    SUPPLY ||--o{ SUPPLYALLOCATION : "allocated via"
    ORDER ||--o{ SUPPLYALLOCATION : "fulfilled via"

    USER {
        uuid id PK
        string name
        string email
        string role
    }
    FARMER {
        uuid id PK
        uuid userId FK
        string location
    }
    BUYER {
        uuid id PK
        string name
    }
    SUPPLY {
        uuid id PK
        uuid farmerId FK
        string produce
        decimal quantity
        string status
    }
    ORDER {
        uuid id PK
        uuid buyerId FK
        string produce
        decimal requiredQuantity
        decimal fulfilledQuantity
        string status
    }
    SUPPLYALLOCATION {
        uuid id PK
        uuid supplyId FK
        uuid orderId FK
        decimal quantity
        string farmerNameSnapshot
        string idempotencyKey
    }
```

## Allocation flow (how a request becomes a state change)

```mermaid
sequenceDiagram
    participant A as Aggregator
    participant API as API
    participant DB as Database

    A->>API: POST /orders/:id/allocations {supplyId, quantity, idempotencyKey}
    API->>DB: Check order status is pending/partially_fulfilled
    API->>DB: Check quantity + fulfilledQuantity <= requiredQuantity
    API->>DB: Check quantity <= (Supply.quantity - SUM existing allocations)
    alt all checks pass
        API->>DB: INSERT SupplyAllocation (idempotencyKey unique)
        API->>DB: UPDATE Order.fulfilledQuantity += quantity (same transaction)
        API->>DB: Recompute Order.status / Supply.status
        API-->>A: 201 Created
    else any check fails
        API-->>A: 404 / 409 / 422 with error envelope
    end
```
