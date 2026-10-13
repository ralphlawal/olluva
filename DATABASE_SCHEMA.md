# Database schema

Postgres (Supabase). Migrations live in `supabase/migrations`, applied in filename order. Every table in `public` has Row Level Security enabled and explicit grants.

## Tables

| Table | Purpose | Who can read | Who can write |
| --- | --- | --- | --- |
| `profiles` | Display name, avatar path, time zone. 1:1 with `auth.users` (anonymous identities included). | Self; current partner | Self: `display_name`, `avatar_path`, `time_zone` only |
| `themes` | Catalogue of space themes and which are premium | Any signed-in user | Nobody (seeded) |
| `couple_spaces` | A shared space: status, theme, accent | Its active members | Functions only |
| `couple_members` | Membership, with `left_at` | Active members of the same space | Functions only |
| `invitations` | Hashed invitation codes and their status | The creator (never the hash column) | Functions only |
| `invitation_attempts` | Redemption attempts, for rate limiting | Nobody | Functions only |
| `blocks` | "Never pair me with this account" | The blocker | Blocker may delete; inserts via `leave_couple` |
| `notes` | The notes history | Active members of the space | Insert own (content columns only); edit/delete via functions |
| `note_reactions` | One reaction per person per note | Active members | `set_reaction` only |
| `memories` | The scrapbook; owns a copy of saved content | Active members | Members: insert (not `kind = 'note'`), edit title/caption/date, delete |
| `important_dates` | Dates and reminder settings | Members; private dates only their owner | Owner, and the partner for shared dates |
| `scheduled_messages` | Queue of surprises | **Author only** | Insert own; edit/cancel via functions |
| `notification_preferences` | Per-category switches and `show_previews` | Self | Self |
| `device_tokens` | APNs tokens | Nobody (not even self) | `register_device_token` / `unregister_device_token` |
| `notification_outbox` | Pending pushes: ids only, no content | Nobody | Triggers; drained by `send-push` |
| `subscriptions` | Verified App Store subscriptions | The owning user | Service role only |
| `widget_tokens` | Hashed, revocable read-only credentials for the widget | Nobody | `issue_widget_token` / `revoke_widget_token` |
| `together_questions` | The curated library of daily questions | Nobody | Migrations only |
| `together_settings` | The time zone a couple's day is reckoned in | Nobody | Functions only |
| `together_moments` | One per couple per day: which question, how many have answered, when it was revealed. **No answer text** | Members | Functions only |
| `together_answers` | Each person's answer. **No API privileges and no policies**: reachable only through the Together functions | Nobody | Functions only |
| `storage_purge_queue` | Media waiting to be removed from Storage | Nobody | Triggers; drained by `purge-storage` |
| `audit_events` | Pairing, unlinking, subscription and deletion events. No content. | Nobody | Functions only |

Relationships: `auth.users` → `profiles` (cascade) → everything keyed to a person. `couple_spaces` → members, invitations, notes, reactions, memories, dates, scheduled messages, Together settings and moments (cascade). `together_moments` → answers (cascade); `profiles` → that person's answers (cascade). `memories.together_moment_id` links a saved moment (unique, cascade).

## Constraints worth knowing
- `couple_members_one_active_per_user`: unique on `user_id` where `left_at is null`. This index is the single-couple rule.
- Two-member limit: enforced under a row lock on the space inside `accept_invitation`.
- `notes.body` ≤ 280 characters; `style` is a JSON object ≤ 8 KB; a live note must have text, a photo or a drawing.
- Media paths must match `couples/<this couple's id>/<uuid>.jpg|png`, checked by a constraint on every table that stores one.
- `memories_one_per_source_note`: a note is saved to Memories at most once.
- `important_dates.remind_days_before` ⊆ {0, 1, 3, 7, 14, 30}, at most four.
- `scheduled_messages.deliver_at` between one minute and two years ahead.

## Client-callable functions (`authenticated` only)
`create_couple_space` · `create_invitation` · `revoke_invitation` · `preview_invitation` · `accept_invitation` · `decline_invitation` · `leave_couple` · `set_couple_theme` · `update_note` · `delete_note` · `mark_note_seen` · `set_reaction` · `save_note_to_memories` · `update_scheduled_message` · `cancel_scheduled_message` · `register_device_token` · `unregister_device_token` · `get_entitlement` · `export_my_data` · `together_today` · `together_submit` · `together_reveal` · `together_moment` · `together_history` · `together_save_memory` · `together_unsave_memory`

The three redemption functions return `{ ok, error }` instead of raising, so that a failed attempt is still recorded for the rate limiter.

## Service-role functions (Edge Functions only)
`record_subscription` · `claim_notifications` · `complete_notification` · `claim_storage_purges` · `complete_storage_purges` · `prepare_account_deletion`

## Scheduled jobs (`pg_cron`)
| Job | Schedule | Does |
| --- | --- | --- |
| `deliver-scheduled-messages` | every minute | Delivers due surprises |
| `enqueue-date-reminders` | hourly at :05 | Queues reminders due at 09:00 local |
| `queue-orphaned-uploads` | 03:20 daily | Queues uploads older than a day that nothing references |
| `purge-ended-spaces` | 03:40 daily | Erases spaces ended more than 30 days ago; trims logs |
| `purge-abandoned-identities` | 04:00 daily | Removes anonymous identities over 30 days old that never chose a name, never joined a space and hold no subscription |
| `together-announce` | hourly at :05 | Queues the morning "new question" notification at 09:00 in a couple's time, for couples who answered one in the last week |
| `review-partner` | every 5 minutes | Keeps the App Review demo partner working (ADR 0010) |
| `send-push`, `purge-storage` | every minute / hourly | Created from SETUP.md (they need the project URL and a secret) |

## Storage
| Bucket | Path | Limits | Access |
| --- | --- | --- | --- |
| `couple-media` (private) | `couples/<couple_id>/<uuid>.jpg` or `.png` | 5 MB, JPEG/PNG | Read and insert: active members of that couple. No update, no client delete (write-once). |
| `avatars` (private) | `<user_id>/avatar.jpg` | 1 MB, JPEG | Write: owner. Read: owner and current partner. |

## Retention
| Data | Kept until |
| --- | --- |
| A deleted note's content | Erased immediately (tombstone row remains) |
| Media no longer referenced | Queued at once; removed on the next purge run |
| An ended space | 30 days after it ended |
| Invitation attempts, sent notifications | 7 days |
| Audit events | 180 days |
| An identity and what it authored | Until the person deletes everything |
| An identity abandoned before doing anything | 30 days |

## Realtime
Published: `notes`, `note_reactions`, `couple_spaces`, `couple_members`, `memories`, `important_dates`, `invitations`, `together_moments` (which holds no answers). Realtime applies the same SELECT policies before delivering a change.
