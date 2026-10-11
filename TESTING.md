# Testing

Four suites. Each can be run by itself; none needs network access, Docker, or an Apple or Supabase account.

## Latest results (10 October 2026)

| Suite | Runs on | Tests | Result |
| --- | --- | --- | --- |
| Database security and Edge Function logic | Node 24 + embedded Postgres 17 | 127 | 127 passed |
| Swift package (`CoupleKit`) | macOS, `swift test` | 98 | 97 passed, 1 skipped (live-server test, needs credentials) |
| App unit tests | iPhone 17 simulator, iOS 26.5 | 55 | 48 passed, **7 skipped** |
| UI tests | iPhone 17 simulator, iOS 26.5 | 29 | 29 passed |

Builds: Debug and Release both build for the simulator, including the widget extension.

**The 7 skipped tests are the StoreKit purchase tests.** StoreKit's local test service only serves apps that are "installed for development", which needs a development team for signing. None is configured on the machine these ran on, so the service refused the configuration (`com.example.couplenotes is not installed for development` in the `storekitd` log). The tests skip with that message instead of failing. Purchase, restore, expiry, refund, pending approval and account binding are therefore **not verified**. Set `DEVELOPMENT_TEAM` and re-run `scripts/build.sh test -only-testing:CoupleNotesTests/PurchaseStoreTests`.

## 0. Against the hosted project
Two suites talk to the real Supabase project. Both need only the publishable key, both create anonymous identities and rows, and both are skipped or not run by default.

```sh
# 47 checks through the public API, as an attacker would reach it
cd supabase/tests
SUPABASE_HOST=<ref>.supabase.co SUPABASE_KEY=<publishable key> node live-check.mjs

# The app's own client, two people, every repository, including Realtime
cd Packages/CoupleKit
SUPABASE_HOST=<ref>.supabase.co SUPABASE_KEY=<publishable key> swift test --filter CoupleSupabaseLiveTests
```
Last run 11 October 2026 against the `olluva` project: 47 of 47 (the client test last passed on 10 October). The checks now call `verify-purchase` and `delete-account` as a signed-in person and delete their own identities at the end; before that, nothing exercised those functions on the real runtime, which hid two faults that the local tests could not see (see CHANGELOG). The client test has found two real bugs, both fixed: paging back through notes returned the boundary note twice, and restarting the live connection for the same space (which the app does when a partner joins) silently stopped live updates.

To remove what they create without touching real users (SQL editor, as an administrator):
```sql
with t as (select id from public.profiles where display_name like 'Live%')
delete from public.couple_spaces
where id in (select couple_id from public.couple_members where user_id in (select id from t));
delete from auth.users where id in (select id from public.profiles where display_name like 'Live%');
```
`live-check.mjs` names its identities `LiveAda`, `LiveBen`, `LiveCal`, `LiveDee`; the client test uses `Live Ada` and `Live Ben`.

## 1. Database and Edge Functions — `supabase/tests`
```sh
cd supabase/tests && npm install && npm test
```
Starts a throwaway Postgres 17 (the `embedded-postgres` package downloads a real server binary), applies `support/supabase_shim.sql` and then every migration, and runs statements the way PostgREST does: `SET ROLE authenticated` plus the JWT claims setting.

The shim recreates the API roles, `auth.users`, `auth.uid()`, the `storage` tables, the Realtime publication and, importantly, Supabase's permissive default grants, which the migrations are responsible for removing.

| File | Covers |
| --- | --- |
| `pairing.test.js` (28) | Account bootstrap; code format and hashing; accept, decline, revoke, expiry, single use; closing an empty space on join; three concurrency races; rate limits; indistinguishable failures; no direct membership writes; unlinking; blocking; anonymous access; RLS enabled everywhere; no function executable by `PUBLIC` |
| `content.test.js` (36) | Server-set author and timestamps; cross-couple isolation for every operation; idempotent send; version conflicts including simultaneous edits; tombstones; validation; seen and reactions; storage path scoping, traversal attempts, write-once media; loss of access on unlinking; avatars; reference-counted purge; memories limits under concurrency; private dates; recurrence maths; reminders; surprises staying secret; exactly-once delivery under overlapping workers and forced replays; cancel-versus-deliver races; plan limits |
| `accounts.test.js` (21) | Anonymous identities held to the same rules as everyone, and only abandoned ones purged; no client write path to subscriptions; shared entitlement and its source; premium following the purchaser; expired, revoked, billing-retry and grace states; one purchase per account; refunds; theme gating; notification queueing without content; previews off by default; preference and token privacy; token hand-over; dead-token cleanup; export contents; export after unlinking; account deletion; retention purge; profile column limits |
| `functions.test.js` (20) | Apple JWS verification against a certificate chain generated with `openssl` (accepts a good chain under the trusted root; rejects any other root, tampered payloads, wrong keys, mismatched chains, expired certificates, `alg: none`, garbage); bundle, product and environment checks; subscription state mapping; notification wording and its privacy rule |

Not covered here: the HTTP handlers of the Edge Functions (they need Deno), APNs itself, `pg_cron` schedules, and Supabase Storage's real behaviour beyond its `objects` table.

## 2. Swift package — `Packages/CoupleKit`
```sh
cd Packages/CoupleKit && swift test
```
| Target | Covers |
| --- | --- |
| `CoupleDomainTests` (45) | Note validation; name rules; invitation code normalising, formatting and links; `DayDate`; next-occurrence rules (the same cases asserted against the SQL); upcoming dates; reminder sanitising; scheduling window; entitlement rules and limits (checked against the database's values); catalogue integrity; error mapping; `NoteFeed` merging, including stale and duplicate events; forgiving style decoding; media path shapes; retry back-off |
| `CoupleLocalBackendTests` (37) | The app's flows end to end on the in-memory backend: starting without sign-up, backing up with an Apple ID, restoring on a new phone, one Apple ID per identity, session expiry; pairing and its edge cases; idempotent send; failed send creates nothing; realtime delivery; version conflicts; deletion; cross-couple isolation; write-once media; memories pagination; limits; private dates; scheduled delivery exactly once; shared entitlement; account deletion; export |
| `CoupleWidgetUITests` (8) | Snapshot round trip; corrupt snapshot falls back to signed-out; only the current note's images are kept; clearing removes all content; Lock Screen text hidden unless opted in; deep links; image decoding failures |

## 3. App unit tests — `Tests/AppTests`
```sh
scripts/build.sh test -only-testing:CoupleNotesTests
```
| Class | Covers |
| --- | --- |
| `ConfigurationTests` (4) | HTTPS-only backend URL; malformed hosts rejected; push environment; UI testing forces the demo backend |
| `NotesStoreTests` (10) | Send empties the outbox; a failed send throws and is never shown as sent; an unsent note survives a relaunch and is delivered exactly once; invalid notes are not queued; discard; stale realtime events; edit conflicts; seen; reaction rollback; purge |
| `SessionStoreTests` (7) | First launch to paired with only a name asked for; backup reflected without changing identity; restore on a new phone; expected versus unexpected sign-out; failed first load and retry; unconfigured release build; missing name |
| `AccountDeletionTests` (2) | Deletion while a live refresh is in flight ends signed out with no error; a failed deletion keeps the account |
| `WidgetBridgeTests` (4) | Snapshot state per session state; the widget never shows your own note; deleted notes disappear; Lock Screen privacy default |
| `ContentStoreTests` (4) | Scheduling validation before any network call; schedule and cancel; memories save and count; dates ordering |
| `ComposerModelTests` (12) | Empty notes; character limit; legible ink on dark paper; sticker limits and bounds; templates; photo crop, resize and layout; unreadable images; drawing rendered to a 1024-pixel transparent PNG; draft persistence; editing does not touch the draft; surprise default time |
| `ImagePipelineTests` (4) | Crop geometry; clamping; avatar size; **location metadata is removed from uploaded photos** |
| `PurchaseStoreTests` (7) | Skipped; see above |

## 4. UI tests — `Tests/UITests`
```sh
scripts/build.sh test -only-testing:CoupleNotesUITests
# also save screenshots for review:
TEST_RUNNER_SCREENSHOT_DIR=/tmp/shots scripts/build.sh test -only-testing:CoupleNotesUITests
```
The app is launched with `-uiTesting -demoScenario <name>`, which runs it on the in-memory backend from a clean state.

| Class | Covers |
| --- | --- |
| `OnboardingUITests` (4) | Privacy explainer before anything is created; getting started asks only for a name (no email or password field exists); first launch to paired; restoring a backed-up space on a new phone |
| `PairingUITests` (3) | Invitation screen and moving on when the partner accepts; wrong code refused, then accept only after confirming who it is from; declining joins nothing |
| `HomeAndNotesUITests` (7) | First-note prompt; opening the latest note, reacting, saving, read state; write, style, sticker, preview, send, then see it was seen; drawing; **a failed send is never reported as sent**; drafts; deleting a note |
| `MemoriesAndDatesUITests` (4) | Timeline, add and remove; empty state; adding a date; planning, limit, and cancelling a surprise |
| `SettingsUITests` (9) | Free theme applies, premium theme leads to the paywall; a partner's premium unlocks themes; notification previews off by default; widget help; paywall honest when the store is unavailable; unlinking keeps the identity; deleting everything needs typed confirmation; no sign-out without a backup, then back up, sign out and restore; the backup offer can be skipped; dark appearance |

Every test attaches screenshots to the result bundle. A failing test also captures the screen it failed on.

## What automated tests do not cover
| Area | Why | How to verify |
| --- | --- | --- |
| Edge Function HTTP handlers | Need Deno and a deployment | `supabase functions serve` and call them |
| Push notifications | Need an APNs key and a device | APP_STORE_CHECKLIST.md "TestFlight" step 5 |
| Widgets on the Home and Lock Screen | Cannot be driven from a test; need the App Group on a signed build | Add the widget by hand on a device |
| StoreKit purchases | Need a signing team (local) and App Store Connect (sandbox) | See the note at the top |
| Anonymous sign-in, backup and restore against Supabase and Apple | Need a project with anonymous sign-ins and the Apple provider, and a signed build | By hand on a device: start, pair, back up, delete the app, reinstall, restore |
| The photo picker and crop gestures | The system picker runs out of process | By hand; the image pipeline behind it is unit tested |
| VoiceOver, largest text sizes | Need a person | APP_STORE_CHECKLIST.md "Accessibility review" |
| Other devices and iOS versions | Only the iOS 26.5 runtime is installed | Install more runtimes; run on a small device (iPhone SE class) and iOS 17 |
| Performance (launch time, scrolling, memory) | Not measured | Instruments on a device |
