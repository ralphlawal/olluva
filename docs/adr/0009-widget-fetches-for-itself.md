# ADR 0009: The widget fetches for itself, with its own narrow credential

Status: accepted · 2026-10-10. Supersedes the refresh strategy in ADR 0004.

## Context
ADR 0004 had the app as the only writer of widget data, relying on a push with `content-available` to wake the app. Measured on a real device, that was not good enough:

- An alert push did wake a backgrounded app, which refreshed the widget.
- A silent push (used when a note is deleted) was accepted by Apple and **never delivered** to the app within a minute, twice.
- Nothing wakes an app the person has closed from the app switcher.

A widget that shows a note its author has deleted is a privacy failure, not a cosmetic one.

## Decision
- The server issues each device a **widget token**: 244 random bits, stored only as a hash, revocable, at most three per identity. It can read exactly what the widget shows (`public.widget_snapshot`: the partner's newest undeleted note, their name, the theme) and nothing else. It cannot write, read history, or act as the user.
- It is deliberately **not** the app's session. Extensions sharing and refreshing the app's session would race the app's own token refresh and could sign the person out.
- The `widget-snapshot` Edge Function accepts that token and returns the snapshot plus two-minute signed URLs for any images.
- `WidgetRemoteRefresher` (in `CoupleWidgetUI`) calls it and writes the App Group snapshot. It runs in two places:
  1. the **widget's timeline provider**, every time iOS asks for a timeline (requested every 15 minutes), so the widget corrects itself with no help from the app;
  2. a **Notification Service Extension**, which iOS runs for every alert push whether the app is open, backgrounded or closed. Pushes carry `mutable-content` for this.
- The app still writes the snapshot whenever it runs, and still revokes the token and clears the container on sign-out. A 403 from the function makes the extension clear the container too.

## Consequences
- A new note reaches the widget within a couple of seconds of the push, even with the app closed (measured: 2 seconds).
- A deleted or edited note is corrected at the widget's next timeline fetch, at the next push, or when the app opens, whichever comes first. This is bounded by iOS's timeline scheduling (commonly around 15 minutes, longer in Low Power Mode), not instant. The silent push is still sent and helps when iOS chooses to deliver it.
- The App Group container now holds a credential. It is file-protected until first unlock, scoped to read-only widget content, and revocable. Someone with a full filesystem image of an unlocked phone could read the partner's latest note with it, which they could also read from the snapshot beside it.
- A third target (`CoupleNotesNotifications`) and App ID.
- Lock Screen privacy and widget style remain device-local and are preserved across remote refreshes.

## Verification
Verified on an iPhone 16: with the app not running, a note inserted on the server caused the widget token to be used 2 seconds later. Database rules for the token are covered by `accounts.test.js` ("widget tokens"); payload mapping by `WidgetRemoteTests`. Not verified: behaviour under Low Power Mode, and the actual interval iOS grants timeline refreshes over a full day.

## Addendum, same day: widget push updates

Measuring on the device showed a second problem. The notification extension fetched the new note within seconds, but iOS did not act on its request to reload the widget: no timeline fetch followed in 45 seconds. A reload requested from an extension is evidently budgeted or ignored.

iOS 26 provides the supported mechanism: **widget push updates**. The widget configuration declares a `WidgetPushHandler`; iOS issues the device's widgets a push token (80 bytes); the server sends an APNs request with push type `widgets` to the topic `<bundle id>.push-type.widgets` and the payload `{"aps":{"content-changed":true}}`; iOS reloads the widget, whose timeline provider fetches the content with the widget token.

- The widget extension carries the `aps-environment` entitlement.
- The app registers the token on every launch via `WidgetCenter.currentPushInfo` (iOS reports it to the extension only when it changes).
- The server sends a widget push for every new note, surprise, edit and deletion, independent of notification permission and preferences.
- On iOS 17 to 25 the widget has no push handler and relies on the notification extension and its timeline.

Measured on an iPhone 16 running iOS 26.6 with the app closed: a new note redrew the widget 3 seconds later; deleting that note redrew it 3 seconds later. The server now records push-triggered fetches and timeline fetches separately (`widget_tokens.push_fetches`, `timeline_fetches`), which is how this was measured and how it can be checked again.

Two mistakes made while building this, both now covered by tests: the push-token check used a regex repetition count above Postgres's limit of 255, so no token could be stored; and the registration function cleared a push token from other rows before checking that the caller's widget token was valid.
