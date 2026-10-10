# ADR 0006: Scheduled messages are a database queue drained by pg_cron

Status: accepted · 2026-10-09

## Context
A surprise must arrive on time whether or not the sender's phone is on, exactly once, and must stay secret until then.

## Decision
- `scheduled_messages` is the queue. A row stores an absolute instant (`timestamptz`) plus the IANA zone the sender chose it in, kept only so the app can show the time back to them.
- Only the author can see a row (RLS), so the partner cannot discover a surprise early.
- `app_private.deliver_due_scheduled_messages()` runs every minute under `pg_cron`. It selects due rows `FOR UPDATE SKIP LOCKED`, re-checks at delivery time that the author is still paired in an active space, inserts the note and marks the row delivered in one transaction.
- The delivered note reuses the scheduled message's id, so a replay cannot create a second note. Cancel takes the same row lock, so cancel-versus-deliver has exactly one winner.
- Media is uploaded when the surprise is scheduled, not at delivery.
- The push notification is queued by the same trigger as any other note, with its own de-duplication key.

## Consequences
- Delivery granularity is one minute.
- No external scheduler or queue service to pay for or operate.
- **Verified** against Postgres 17: overlapping workers, forced replays, cancel races, unlink before delivery, plan limits. **Not verified:** the `pg_cron` schedule itself, which is created only where the extension exists.
