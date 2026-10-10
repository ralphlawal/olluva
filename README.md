# Olluva

A private iOS app for two people. Leave each other notes, drawings and photos that show up on each other's Home Screen.

Native Swift and SwiftUI, WidgetKit, StoreKit 2, with a Supabase backend. iPhone, iOS 17+.

> **Status: pre-release.** The app runs end to end in the simulator on an in-memory demo backend, and the backend's rules are tested against a real Postgres. It has **not** yet been connected to a hosted Supabase project, signed for a device, or submitted anywhere. What is and is not verified is listed under [Known limitations](#known-limitations).

## Quick start
```sh
brew install xcodegen
xcodegen generate
open CoupleNotes.xcodeproj
```
Run the `CoupleNotes` scheme on a simulator. With no backend configured, a Debug build starts in demo mode. To land in a populated space, add the launch arguments `-demoScenario paired`.

Full instructions, including Supabase, signing, push and purchases: [SETUP.md](SETUP.md).

## What's here
| | |
| --- | --- |
| [PRODUCT_SPEC.md](PRODUCT_SPEC.md) | What the product is, its rules, free vs Premium, open decisions |
| [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) | Art direction, tokens, components, accessibility |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Code layout and how the pieces fit; decisions in [docs/adr](docs/adr) |
| [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) | Tables, policies, functions, jobs, storage, retention |
| [SECURITY.md](SECURITY.md) | Threat model, controls and how each is tested, what is not claimed |
| [TESTING.md](TESTING.md) | Every test suite, how to run it, and the latest results |
| [SETUP.md](SETUP.md) | Tools, configuration, Supabase, Apple capabilities, StoreKit |
| [APP_STORE_CHECKLIST.md](APP_STORE_CHECKLIST.md) | Release readiness, privacy questionnaire, review notes, TestFlight |
| [CHANGELOG.md](CHANGELOG.md) | What has changed |

## Running the tests
```sh
# Database security rules and Edge Function logic (no Docker needed)
cd supabase/tests && npm install && npm test

# Domain rules, in-memory backend, widget snapshot (macOS, about a second)
cd Packages/CoupleKit && swift test

# App unit tests and UI tests in the simulator
scripts/build.sh test
```

## Known limitations

### Awaiting configuration (built, not yet exercised for real)
These are implemented and their logic is tested locally, but they need credentials or hardware that were not available.

| Area | What is needed | What has been verified instead |
| --- | --- | --- |
| Supabase backend | A project; `supabase db push` | Migrations applied to Postgres 17 with a shim for Supabase's roles; security rules tested there |
| Supabase client (`CoupleSupabase`) | A project URL and anon key | Compiles against supabase-swift 2.55; not run against a server |
| Realtime | A project | Event handling tested on the in-memory backend |
| Edge Functions | Deployment (Deno) | JWS verification, subscription mapping and notification text tested with Node; the HTTP handlers themselves have not been run |
| `pg_cron` jobs | The extension enabled | The functions they call are tested; the schedules are not |
| Push notifications | APNs key, signed build, real device | Token registration and outbox logic tested; no push has been sent |
| Sign in with Apple | Capability on a signed build | Not exercised |
| Email confirmation and reset codes | Supabase email templates | Flow tested on the in-memory backend |
| Widgets on a Home or Lock Screen | A signed build with the App Group | Snapshot store tested; widget views rendered inside the app; extension builds and embeds |
| Purchases (StoreKit 2) | A development team for signing (then `PurchaseStoreTests` run locally); App Store Connect products and a sandbox account for the real thing | **Nothing end to end.** The purchase code compiles and the paywall's unavailable state is tested; the 7 StoreKit tests skip without a signing team |
| Partner unlocking from a purchase | Deployed `verify-purchase` | Database entitlement rules tested |

### Not built
- End-to-end encryption (see ADR 0007). The app does not claim it.
- A Notification Service Extension (would make widget refresh on push more reliable).
- Camera capture and in-app QR scanning. The system photo picker and Camera app cover both.
- iPad layout, interactive widgets, languages other than English (strings are localisable).
- Analytics and crash reporting. Diagnostics are local `os.Logger` output only.
- Offline reading from a local database. Loaded content stays visible offline; unsent notes and drafts are kept on disk.

### Placeholders to replace before release
Bundle and App Group identifiers (working values in `Config/Secrets.xcconfig`) · product identifiers and prices · the Privacy Policy, Terms and support pages that the app links to on www.olluva.app, and the support@olluva.app mailbox · app icon (generated; needs design review) · security contact.

### Other things to know
- Swift language mode is 5; strict concurrency is a follow-up.
- Rate limiting is per account, inside the database. Network-level limits rely on Supabase's defaults.
- Accessibility has been built in (labels, traits, Dynamic Type, Reduce Motion, contrast) but not yet audited by hand on a device.
- UI tests have only been run on one simulator (iPhone 17, iOS 26.5). No other simulator runtimes were installed.
- The in-memory backend re-implements server rules for tests and demo mode. It is compiled only into Debug builds' code paths and is labelled on screen wherever it is active.

## Licence
Not yet chosen. All rights reserved until one is.
