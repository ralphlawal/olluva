# Architecture

Decisions and their reasons are in `docs/adr`. This file is the map.

## Layout
```
App/                         The iOS app target
  CoupleNotesApp.swift       Entry point, app delegate (push token, background push)
  Core/                      AppEnvironment (composition root), configuration, error
                             presentation, diagnostics, DemoController (DEBUG only)
  Stores/                    @Observable state: session, notes + outbox, media,
                             memories, dates, schedule, purchases, notifications,
                             widget bridge, drafts, local settings, router
  Features/                  Screens, one folder per area
  Resources/                 Assets, string catalogue, StoreKit config, privacy manifest
Widgets/                     WidgetKit extension (thin: reads a snapshot, draws it)
Packages/CoupleKit/
  Sources/CoupleDomain       Models, rules, validation, repository protocols. No I/O.
  Sources/CoupleDesign       Tokens, components, the note renderer
  Sources/CoupleWidgetUI     Widget snapshot store, deep links, widget faces
  Sources/CoupleLocalBackend In-memory repositories (tests, previews, demo mode)
  Sources/CoupleSupabase     Production repositories on supabase-swift
  Tests/                     Package tests (run with `swift test`)
Tests/AppTests               App unit tests (hosted in the simulator)
Tests/UITests                UI tests on the demo backend
supabase/
  migrations/                Versioned SQL
  functions/                 Edge Functions (Deno) and their shared, Node-testable logic
  tests/                     Database and function tests (Node + embedded Postgres)
Config/                      xcconfig files; Secrets.xcconfig is git-ignored
scripts/                     build.sh, run_sim.sh, make_app_icon.swift
docs/adr/                    Architecture decision records
project.yml                  XcodeGen project definition
```

## Dependency direction
```
            ┌──────────────┐
            │ CoupleDomain │  models · rules · repository protocols
            └──────┬───────┘
      ┌────────────┼───────────────┬──────────────────┐
┌─────▼──────┐ ┌───▼──────────┐ ┌──▼───────────────┐
│CoupleDesign│ │CoupleSupabase│ │CoupleLocalBackend│
└─────┬──────┘ └───┬──────────┘ └──┬───────────────┘
┌─────▼────────┐   │               │
│CoupleWidgetUI│   │               │
└───┬──────┬───┘   │               │
    │      └───────┴───────┬───────┘
┌───▼────┐            ┌────▼───┐
│Widgets │            │  App   │
└────────┘            └────────┘
```
Feature code imports `CoupleDomain`, `CoupleDesign` and `CoupleWidgetUI`. Only `AppEnvironment` knows which backend is in use. The widget extension links neither backend.

## Runtime shape
`AppEnvironment` is created once and injected through the SwiftUI environment. It builds the `Backend` (a struct of eleven repository protocols), creates each store, and owns the behaviour that spans stores:

- **Session → phase.** `SessionStore` turns auth state, profile and space into one of: launching, not configured, signed out, load failed, unpaired, paired. `RootView` switches on it.
- **Live sync.** When there is a space, one Realtime stream delivers `SpaceEvent`s. Notes are applied directly; other events say which list to re-read. On reconnect, and whenever the app returns to the foreground, everything is re-read, because Realtime is not assumed to have delivered every change.
- **Widget publishing.** Any change to notes or session republishes the snapshot (skipped when nothing visible changed).
- **Wiping.** Signing out, unlinking and deleting the account clear the outbox, drafts, media cache, widget container, stored invitation and delivered notifications.

## A note's journey
1. The composer builds an `OutgoingNote`: content plus the bytes of any photo (cropped, resized, re-encoded) and drawing (rendered to a 1024-pixel transparent PNG).
2. `NotesStore.send` writes it to the outbox on disk, then uploads media and inserts the note, using an id fixed when composition began.
3. Only when the server has returned the stored row does `send` return. The composer closes then, and not before. On failure the composer says what happened; a retryable failure can be left to the outbox, which retries with back-off and on the next foreground.
4. A trigger queues a push for the partner. Their app receives the row over Realtime, or fetches it when a push or a foreground wakes it, and republishes its widget.

## Errors
Backends translate everything into `AppError`. Screens present `error.message` inline. `AppError.isRetryable` decides whether a retry is offered and whether the outbox keeps trying. Logs carry `diagnosticCode`, never content.

## Concurrency
Stores are `@MainActor`. Repositories are `Sendable` and do their work off the main actor. Image decoding and encoding run in detached tasks. The language mode is Swift 5.

## Local persistence
| What | Where | Protection | Cleared |
| --- | --- | --- | --- |
| Session | Keychain (SDK) | Keychain | Sign-out, deletion |
| Issued invitation code | Keychain, this device only | After first unlock | Sign-out |
| Unsent notes | Application Support/Outbox | Until first unlock | When sent, discarded, or on wipe |
| Draft | Application Support/Draft | Until first unlock | When sent, discarded, or on wipe |
| Media cache | Caches/Media | Until first unlock | Wipe; the system may evict it |
| Widget snapshot | App Group container | Until first unlock | Wipe |
| Device preferences | UserDefaults | | Kept (not account data) |

Nothing else is cached. There is no offline database: content already loaded stays on screen when the connection drops, and reads resume when it returns.

## Testing seams
- `LocalWorld` implements the server's rules in memory, with a controllable clock and switchable failures.
- Every store takes its `Backend` (and, where relevant, its storage directory) in its initialiser.
- UI tests launch with `-uiTesting -demoScenario <name>`.
- Edge Function logic that matters (JWS verification, subscription state, notification wording) is in modules with no Deno imports, so Node can test it.
