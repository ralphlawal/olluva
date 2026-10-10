# Product specification

Name: **Olluva** · www.olluva.app. Category: Lifestyle. Platform: iPhone, iOS 17+.

## Promise
> Make your favourite person part of your everyday.

A private space for exactly two people to leave each other notes, drawings and photos that show up on each other's Home Screen.

## Principles, and how each is honoured
| Principle | In the product |
| --- | --- |
| Emotional value before feature count | Home shows one thing: the newest note from your partner. Everything else is plain rows beneath it. |
| Every control works | No placeholder buttons. Anything not available says why (for example the paywall when the store cannot be reached). |
| Privacy and consent by default | Notification and Lock Screen text is hidden until you opt in. You see who an invitation is from and accept it before anything is joined. |
| Fast onboarding | No sign-up. Welcome → your name → invite or enter a code. No email, password or carousel. |
| No dark patterns | No streaks, no countdowns, no pre-ticked upsells, no fake prices. The paywall has an ordinary close button. |
| A free tier with real value | See below. |

## Product rules
0. **No account is needed.** Starting creates a private identity held on the phone. A person may back it up with their Apple ID so it can be restored on another phone; without a backup, losing the phone means losing access to the space (ADR 0008).
1. A person belongs to at most one space. A space has at most two members.
2. Pairing is by invitation only: a 10-character code, link or QR. Codes are single-use, expire after 48 hours, can be replaced, and are rate limited. Nobody is ever paired automatically.
3. Notes are a history. Either partner can send at any time. Only the author can edit or delete a note.
4. A note may contain up to 280 characters of text, one photo, one drawing and up to 8 stickers, on a chosen paper.
5. A note you receive can be reacted to (one reaction), saved to Memories, and replied to. Opening it marks it seen; the sender can see that.
6. Deleting a note removes it for both people and from widgets. A copy saved to Memories stays.
7. A surprise (scheduled note) is visible only to its author until it is delivered. It is delivered by the server at the chosen instant.
8. Important dates may be shared or private to the person who added them. Reminders arrive around 09:00 in the recipient's own time zone.
9. **Unlinking** closes the space for both people immediately; accounts remain. Content can be exported for 30 days, then it is erased. **Delete everything** erases the person's identity, any backup, and everything they authored; their partner keeps their own identity and writing.
10. One subscription covers the space. It belongs to the buyer and follows them if they unlink.

## Free and Premium
Defined in one place: `ProductConfiguration` (client) and `app_private.couple_limit` (server, authoritative).

| | Free | Premium |
| --- | --- | --- |
| Notes, drawings, photos | Unlimited | Unlimited |
| Papers | 4 | 10 |
| Inks | 7 | 11 |
| Stickers | 6 | 14 |
| Drawing tools | Pen, eraser | + marker, pencil |
| Templates | 3 | 8 |
| Themes | 2 | 6, plus a custom accent colour |
| Widget styles | 2 | 4 |
| Widget families | All | All |
| Memories | 30 | 2,000 |
| Surprises waiting at once | 1 | 50 |
| Important dates | 100 | 100 |

Product identifiers are placeholders: `com.example.couplenotes.premium.monthly` and `.yearly`. The prices in `Products.storekit` exist only so StoreKit can be tested locally; they are not a pricing decision.

## Screens
Welcome · Privacy explainer · Restore a backed-up space · Name step · Pairing chooser · Invitation (code, QR, share) · Enter code · Accept or decline · Notification priming · Today (home) · Composer (words, draw, photo, style, stickers) · Photo crop · Recipient preview · Send later · Note detail · Earlier notes · Memories timeline · Memory detail · Add or edit a moment · Us · Date editor · Personalise (themes, accent, widget style, appearance) · Widget help · Backup offer · Settings · Profile · Back up your space · Notification settings · Unlink · Delete everything · Premium.

## Deliberately out of scope for the first release
End-to-end encryption (ADR 0007) · iPad layout · camera capture (the system photo picker is used, which needs no permission) · QR scanning inside the app (the system Camera opens the invitation link) · interactive widgets · a Notification Service Extension · more than one language.

## Open decisions for the owner
1. **Product name: decided, Olluva.** Still to do: confirm trademark and App Store name availability.
2. **Pricing** and whether to offer an introductory offer.
3. **Bundle identifier, App Group and URL scheme** (`olluva://`). Universal Links need a domain.
4. **Privacy Policy, Terms and support pages.** The app links to `/privacy`, `/terms` and `/support` on www.olluva.app and to support@olluva.app. Those pages and that mailbox need to exist before release.
