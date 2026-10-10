# ADR 0002: Supabase, with every rule enforced in the database

Status: accepted · 2026-10-09

## Context
Relationship content is highly personal. A client can be modified, so nothing the client does can be what keeps one couple's data from another, or what decides who is premium.

## Decision
- Supabase (Postgres, Auth, Storage, Realtime, Edge Functions).
- Row Level Security on every table in `public`. Grants are stated explicitly per table and column; Supabase's default `GRANT ALL` to API roles is revoked in each migration.
- Anything that carries a rule is a `SECURITY DEFINER` function with a pinned empty `search_path`: pairing, note edits and deletes, reactions, saving memories, scheduling, device tokens, themes. Clients have no direct write access to membership, invitations, subscriptions, reactions, or server-controlled columns.
- Helper functions used by policies live in `app_private`, which is not an exposed API schema.
- Functions are executable only if named in the final lockdown migration; `EXECUTE` is revoked from `PUBLIC`, `anon` and `authenticated` first.
- Expected failures raise a stable `snake_case` message that the client maps to a typed `AppError`. Messages never contain user content.

## Consequences
- The security boundary is testable without the app: `supabase/tests` applies the migrations to a real Postgres 17 and attacks them (102 tests).
- More SQL than a client-heavy design, and the in-memory backend re-implements the rules for tests. Both are covered by tests so they cannot drift silently.
- Authenticated downloads are used for media instead of signed URLs: the request carries the user's token and Storage evaluates the SELECT policy, so there is no URL that could be copied or leaked. Signed URLs remain available if media ever needs to be handed to another process.
