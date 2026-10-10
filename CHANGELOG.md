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
- **No sign-up.** "Get started" creates a private identity on the phone; the only thing asked for is a name. Email, password, confirmation codes and password reset are removed. A space can be backed up with Sign in with Apple (offered once after pairing, and in Settings) and restored on a new phone. Sign-out is offered only once backed up. "Delete account" is now "Delete everything". Abandoned identities are purged after 30 days. See ADR 0008.
- The product is named **Olluva**. Invitation and widget links use the `olluva://` scheme, and the app's legal and support links point at www.olluva.app.

### Deployed
- The database is live on the `olluva` Supabase project (eu-west-1): 11 migrations, anonymous sign-ins and manual linking on, five scheduled jobs running.

### Fixed during development
- Paging back through notes could return the boundary note twice (found by the live client test).
- A shared media-release trigger read a column that exists on only one of its tables, breaking every note update (caught by the database tests).
- The invitation code field rewrote its text on each keystroke and dropped characters when typed quickly (caught by UI tests).
- Form titles scrolled underneath the status bar with no bar background (caught in simulator review).
- The composer's placeholder was truncated at its display size.

### Not yet verified
See "Known limitations" in README.md.
