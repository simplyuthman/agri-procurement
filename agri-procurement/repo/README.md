# Agricultural Procurement & Supply Coordination Platform — Design Package

This repository holds the pre-code design artifacts for the platform: the
product requirements, the data model, the API design, the reasoning behind
every hard design decision, and a schema proof plan that shows the model
actually enforces the rules it claims to.

Nothing here is application code. This is the thinking that should happen
**before** anyone opens an editor to write a server.

## Contents

| Doc | Covers |
|---|---|
| [`docs/01-prd.md`](docs/01-prd.md) | What the product does, who uses it, the 5 core user actions |
| [`docs/02-data-model.md`](docs/02-data-model.md) | Entities, fields, relationships, ER diagram |
| [`docs/03-api-design.md`](docs/03-api-design.md) | Endpoints for each of the 5 core actions, plus CRUD and error format |
| [`docs/04-design-decisions.md`](docs/04-design-decisions.md) | The seven hard questions: normalization, money, state machines, time, IDs, constraints, indexes |
| [`docs/05-schema-proof.md`](docs/05-schema-proof.md) | The migration plan, the 5 key queries, and 3 inserts designed to fail |
| [`db/migrations/001_init_schema.sql`](db/migrations/001_init_schema.sql) | Runnable SQL implementing the schema, constraints, and triggers |
| [`db/proof/invalid_inserts_test.sql`](db/proof/invalid_inserts_test.sql) | The 3 invalid-insert proof script from `05-schema-proof.md`, ready to run |

## Reading order

1. Start with the PRD to understand the 5 actions the product must serve.
2. Read the data model — every table exists because an action needs it.
3. Read the API design — every endpoint maps back to one of the 5 actions.
4. Read the design decisions doc for the "why" behind every non-obvious
   choice (denormalization, no money model in this MVP, state machines,
   soft vs. hard delete, UUIDs, constraints, indexes).
5. Run the schema proof to see the constraints actually reject bad data.

## Core invariant this whole design protects

> A farmer's supply listing can never be allocated beyond what it actually
> has, and a buyer's order can never be recorded as fulfilled beyond what
> was actually requested.

Every constraint, trigger, and status transition in this package exists in
service of that one sentence.
