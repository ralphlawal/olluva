# ADR 0005: One subscription covers the couple; the server decides

Status: accepted · 2026-10-09

## Context
A couple should not need two subscriptions. Apple's rules tie a purchase to the Apple ID that made it; the app must not grant premium because a client says so.

## Decision
- A subscription row belongs to the **account** that bought it. Premium is a property of the **space**: it is premium while either active member has a live subscription (`couple_is_premium`). If the couple unlinks, premium follows the purchaser.
- The purchase sets `appAccountToken` to the buyer's user id. The client sends the StoreKit-signed transaction (JWS) to the `verify-purchase` Edge Function, which verifies Apple's certificate chain (pinned to Apple Root CA - G3), the bundle id, the product id and the environment, checks the token matches the caller, and only then writes the row. `app-store-notifications` does the same for renewals, expiries, refunds and revocations.
- One Apple subscription backs one identity at a time, and it follows the device that holds it. *(Revised 11 October 2026.)* Originally a second identity presenting the same transaction was refused. With no accounts ([ADR 0008](0008-no-sign-up.md)) an identity is replaced whenever someone reinstalls or starts over, while the purchase stays with their Apple ID, so that rule made "Restore purchases" impossible for exactly the people who need it. Now a caller who presents an Apple-signed transaction claims the subscription (`claim_subscription`), and it leaves whichever identity had it. The cost: a signed transaction copied off someone's device could be used to take their subscription to another space, and they would take it back the next time their app opened. App Store server notifications update a subscription's status and never change its owner.
- Clients can read their own subscription rows only. There is no client-callable path that inserts or updates one.
- On the purchaser's own device, a transaction that StoreKit has verified locally also unlocks premium (covers offline use and the moment before the server responds). The partner's access, and all server-enforced limits, depend on the server record alone.
- Quantity limits (memories, pending surprises), premium themes and custom accents are enforced in the database. Cosmetic items (papers, inks, stickers, drawing tools, widget styles) are gated in the client only; forging one gains nothing that costs us anything.

## Consequences
- The free tier is real: unlimited notes, drawing, photos, 4 papers, 7 inks, 6 stickers, 2 themes, 30 memories, 1 pending surprise, all widget families.
- Family Sharing is off: the couple model replaces it.
- **Verified:** JWS verification and subscription state mapping, with a generated certificate chain; database refusal of every client write to entitlements; that the paywall reports the store as unavailable instead of showing invented prices.
- **Not verified:** the StoreKit purchase, restore, expiry and refund flows. Tests for them exist (`PurchaseStoreTests`) but skip here, because StoreKit's local test service only serves builds signed with a development team. Also not verified: the deployed Edge Functions and real App Store sandbox transactions.
