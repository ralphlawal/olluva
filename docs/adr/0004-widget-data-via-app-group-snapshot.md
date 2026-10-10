# ADR 0004: Widgets read a snapshot from the App Group; they hold no session

Status: partly superseded by ADR 0009 (the widget now also fetches for itself) · 2026-10-09

## Context
Widgets are a first-class feature, but iOS decides when they refresh, they run under a tight memory limit, and they are visible on the Lock Screen.

## Decision
- The app is the only writer. After any change that could alter what a widget shows, `WidgetBridge` writes one small JSON snapshot plus at most two downsized image files into the App Group container, then calls `WidgetCenter.reloadAllTimelines()`.
- The widget extension only reads that snapshot. It has no Supabase client, no token and no network access to the backend, so it cannot show anything the signed-in app was not authorised to read.
- Files use `completeUntilFirstUserAuthentication` protection. The container only ever holds the one note on display; it is wiped on sign-out, unlinking and account deletion.
- Lock Screen widgets hide note text by default (`hidesContentOnLockScreen`) and are marked `privacySensitive()`.
- Refresh strategy, in order of reliability: (1) the app writes while in the foreground, including from Realtime events; (2) a push with `content-available` wakes the app to fetch and republish; (3) a 30-minute timeline policy as a fallback hint.
- The widget views live in `CoupleWidgetUI` and are reused inside the app for previews, so what a person previews is what they get.

## Consequences
- We do not promise instant widget updates anywhere in the product, and the in-app copy says so.
- Background pushes are throttled by iOS. A Notification Service Extension that fetches the note when an alert arrives would make updates more reliable; it needs the session shared through a Keychain access group and is left as a follow-up.
- **Verified:** snapshot store, widget views rendered in-app, and that the extension builds, embeds and is signed for the simulator. **Not verified:** the widget on a real Home Screen or Lock Screen, and push-triggered refresh (needs a signed build on a device).
