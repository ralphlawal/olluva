# ADR 0007: No end-to-end encryption in the first release, and no claim of it

Status: accepted · 2026-10-09

## Context
Notes are intimate, and E2EE is the strongest answer to "can anyone else read this?". It is also in direct tension with features this product is built on.

## Decision
The first release does **not** implement end-to-end encryption and does not claim to. Content is encrypted in transit (TLS) and at rest by the platform, and access is restricted by RLS to the two members of a space. The in-app privacy explainer states this plainly.

## What E2EE would cost, if adopted later
| Feature | Impact |
| --- | --- |
| Widgets | Workable: the app decrypts and writes plaintext to the App Group, as now. |
| Notification previews | The server could no longer write the preview. Needs a Notification Service Extension holding the key to decrypt on device. |
| Scheduled messages | The server can still deliver an opaque blob on time. No impact on timing; the push text would be generic. |
| Date reminders | Titles would have to be encrypted too, so reminders would become generic unless decrypted on device. |
| Multi-device and reinstall | The hard part. Needs key backup (iCloud Keychain or a recovery phrase) and a device-linking flow; losing the key loses the history. |
| Data export | Would move from the server to the device. |
| Account recovery | Password reset could no longer restore access to content. |
| Server-side validation | Length limits and content checks move to the client. |

A credible design would be a per-space symmetric key, wrapped to each partner's device key (Curve25519), exchanged during pairing, with iCloud Keychain sync for multi-device. It needs an independent review before any claim is made.

## Consequences
Honest positioning today, and a documented path rather than a retrofit under pressure.
