# ADR 0003: Notes are a history; conflicts are prevented by design and by version checks

Status: accepted · 2026-10-09

## Context
"Two partners editing around the same time" must never silently lose a newer note. A single shared "current note" row would make every send a potential conflict.

## Decision
- Every note is its own row with a client-generated UUID. "The latest note" is a query, not a row. Two partners therefore never write to the same record.
- Only the author can edit a note. Every edit carries the version it was based on; `update_note` rejects a stale version with `version_conflict`. The client then reloads and shows the newer content.
- Sending is idempotent on the note id: a retry of the same send returns the stored note. The client keeps unsent notes in a persistent outbox and retries with the same id.
- Timestamps, author, version and origin are set by the server in a `BEFORE INSERT` trigger. Clients are not granted those columns.
- Deleting is a soft delete: content is erased immediately and a tombstone remains, so the partner's device and widget learn that the note is gone. `NoteFeed` never lets an older version replace a newer one, so a late realtime event cannot resurrect it.

## Consequences
- Note history exists from day one; the home screen simply shows the newest received note.
- "Seen" is the only field set by the non-author, through `mark_note_seen`, and it does not bump the version.
