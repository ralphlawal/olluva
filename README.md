# Olluva

A private iOS app for two people. Leave each other notes, drawings and photos that show up on each other's Home Screen. No account needed.

Native Swift and SwiftUI, WidgetKit, StoreKit 2, with a Supabase backend. iPhone, iOS 17+.

> **Status: pre-release.** The database is deployed to a hosted Supabase project, and both its security rules and the app's client have been tested against it. The app runs on a device. The server functions are deployed and a push notification has been delivered through Apple to a real device. Purchases are not set up, and nothing has been submitted anywhere. What is and is not verified is listed under [Known limitations](#known-limitations).

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
| Running the app itself against the server on two phones | Two devices | The client library is verified against the server (below); the full app on two real phones is not |
| `verify-purchase`, `app-store-notifications` | App Store Connect products and a sandbox purchase | Deployed; they start and reject bad input. No real transaction has been through them |
| `delete-account`, `purge-storage` | Exercising them for real | Deployed; they start and refuse unauthorised calls. Not yet run to completion |
| Scheduled delivery on the real server | Scheduling a note and waiting | Jobs are installed and running; a scheduled note has not been watched arriving |
| Backup and restore with Sign in with Apple | The capability on a signed build; Apple provider and manual linking enabled in Supabase | Flow tested on the in-memory backend with a stand-in for the Apple ID; the real Apple and Supabase exchange has not run |
| Widget timing over a full day | Living with it on a phone | Verified on an iPhone 16 (iOS 26.6) with the app closed: the widget redraws about 3 seconds after a note is sent, and again 3 seconds after it is deleted. Not measured: iOS 17 to 25 (no widget push there), Low Power Mode, the Lock Screen variants, and Apple's daily budget for widget pushes |
| Purchases (StoreKit 2) | A development team for signing (then `PurchaseStoreTests` run locally); App Store Connect products and a sandbox account for the real thing | **Nothing end to end.** The purchase code compiles and the paywall's unavailable state is tested; the 7 StoreKit tests skip without a signing team |
| Partner unlocking from a purchase | Deployed `verify-purchase` | Database entitlement rules tested |

### Verified against the hosted project
Schema and policies (66 live API checks), anonymous sign-in, pairing, notes, Realtime delivery, private media through the real Storage API, memories, dates, scheduling, themes, notification preferences, device tokens, avatars and export, all through the app's own Supabase client. See TESTING.md.

### Not built
- End-to-end encryption (see ADR 0007). The app does not claim it.
- Camera capture and in-app QR scanning. The system photo picker and Camera app cover both.
- iPad layout, interactive widgets, languages other than English (strings are localisable).
- CAPTCHA or App Attest on identity creation (see ADR 0008).
- Analytics and crash reporting. Diagnostics are local `os.Logger` output only.
- Offline reading from a local database. Loaded content stays visible offline; unsent notes and drafts are kept on disk.

### Placeholders to replace before release
Bundle and App Group identifiers (working values in `Config/Secrets.xcconfig`) · product identifiers and prices · legal review of the draft Privacy Policy and Terms in `site/` (published at https://ralphlawal.github.io/olluva/ until www.olluva.app is pointed at it), and a support contact address · app icon (generated; needs design review) · security contact.

### Other things to know
- Swift language mode is 5; strict concurrency is a follow-up.
- Rate limiting is per account, inside the database. Network-level limits rely on Supabase's defaults.
- Accessibility has been built in (labels, traits, Dynamic Type, Reduce Motion, contrast) but not yet audited by hand on a device.
- UI tests have only been run on one simulator (iPhone 17, iOS 26.5). No other simulator runtimes were installed.
- The in-memory backend re-implements server rules for tests and demo mode. It is compiled only into Debug builds' code paths and is labelled on screen wherever it is active.

## Licence
Not yet chosen. All rights reserved until one is.
