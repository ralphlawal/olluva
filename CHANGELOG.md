# Changelog

All notable changes to this project are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Backend**: Supabase schema with Row Level Security on every table; database functions for pairing, notes, reactions, memories, dates, scheduled delivery, device tokens, entitlement, export and account deletion; private storage buckets with path-scoped policies; reference-counted media purge; retention jobs.
- **Edge Functions**: `verify-purchase`, `app-store-notifications`, `send-push`, `purge-storage`, `delete-account`.
- **iOS app**: welcome, account creation, sign-in, email confirmation, password recovery, Sign in with Apple; invitation pairing with code, link and QR; home; composer with text, drawing (PencilKit), photo with crop, papers, inks, typefaces, stickers, templates, recipient preview, drafts and scheduled sending; note detail with reactions, read state, reply, edit and delete; notes history; memories timeline; important dates with reminders and private dates; surprises; themes, accent colour, widget styles and appearance; settings, notification preferences, data export, unlinking with optional block, account deletion; StoreKit 2 paywall with shared couple entitlement.
- **Widgets**: Home Screen small and medium, Lock Screen rectangular, circular and inline, reading a snapshot from the App Group container.
- **Demo mode** (Debug builds only): an in-memory backend with five scenarios, for development, simulator review and UI tests.
- **Tests**: database security suite on embedded Postgres 17, Edge Function logic tests, Swift package tests, app unit tests including StoreKit, and UI tests for the main flows.
- **Documentation**: product spec, design system, architecture and ADRs, schema, security, testing, setup, App Store checklist.

### Changed
- **Public site**: landing, privacy, terms and support pages in `site/`, published with GitHub Pages; the app's links point there. The policy and terms are drafts awaiting legal review.
- **No sign-up.** "Get started" creates a private identity on the phone; the only thing asked for is a name. Email, password, confirmation codes and password reset are removed. A space can be backed up with Sign in with Apple (offered once after pairing, and in Settings) and restored on a new phone. Sign-out is offered only once backed up. "Delete account" is now "Delete everything". Abandoned identities are purged after 30 days. See ADR 0008.
- The product is named **Olluva**. Invitation and widget links use the `olluva://` scheme, and the app's legal and support links point at the public site (`site/`, published with GitHub Pages).

### Fixed
- The push environment reported to the server now comes from how the build was signed (its provisioning profile), not its configuration. A Release build run from Xcode used to register a development token as `production`, which would have stopped notifications and widget updates.
- A push token can only be registered under one environment; registering it again replaces the other copy. Previously a rejected duplicate removed the working registration too.

### Deployed
- Server functions are live, and push notifications are sent the moment a note is saved (verified: Apple accepted a notification for a real device). A once-a-minute sweep retries anything missed.
- The database is live on the `olluva` Supabase project (eu-west-1): 11 migrations, anonymous sign-ins and manual linking on, five scheduled jobs running.

### Fixed during development
- The widget still did not redraw when a note arrived: iOS ignored reload requests made from the notification extension. The server now sends iOS 26 widget push updates, which redraw the widget within seconds for new, edited and deleted notes, with the app closed (measured on device).
- The widget did not update unless the app was opened. iOS was not delivering silent pushes, and never wakes a closed app. The widget now fetches for itself with a narrow read-only token, and a notification extension refreshes it when a push arrives, even with the app closed (ADR 0009).
- A deleted note could stay on the partner's widget. Deletes and edits now queue a refresh, and the widget corrects itself on its own schedule.
- If iOS launched the app in the background for a push, it never finished starting up.
- Live updates stopped for the person who sent the invitation: their connection was restarted when the partner joined, and the old connection closing took the new one down. Each connection now has its own channel (found on a real device, reproduced by the live client test).
- Paging back through notes could return the boundary note twice (found by the live client test).
- A shared media-release trigger read a column that exists on only one of its tables, breaking every note update (caught by the database tests).
- The invitation code field rewrote its text on each keystroke and dropped characters when typed quickly (caught by UI tests).
- Form titles scrolled underneath the status bar with no bar background (caught in simulator review).
- The composer's placeholder was truncated at its display size.

### Not yet verified
See "Known limitations" in README.md.
