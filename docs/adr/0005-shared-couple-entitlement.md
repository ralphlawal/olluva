# ADR 0005: One subscription covers the couple; the server decides

Status: accepted · 2026-10-09

## Context
A couple should not need two subscriptions. Apple's rules tie a purchase to the Apple ID that made it; the app must not grant premium because a client says so.

## Decision
- A subscription row belongs to the **account** that bought it. Premium is a property of the **space**: it is premium while either active member has a live subscription (`couple_is_premium`). If the couple unlinks, premium follows the purchaser.
- The purchase sets `appAccountToken` to the buyer's user id. The client sends the StoreKit-signed transaction (JWS) to the `verify-purchase` Edge Function, which verifies Apple's certificate chain (pinned to Apple Root CA - G3), the bundle id, the product id and the environment, checks the token matches the caller, and only then writes the row. `app-store-notifications` does the same for renewals, expiries, refunds and revocations.
- One Apple subscription backs one account: a second account presenting the same transaction is refused.
- Clients can read their own subscription rows only. There is no client-callable path that inserts or updates one.
- On the purchaser's own device, a transaction that StoreKit has verified locally also unlocks premium (covers offline use and the moment before the server responds). The partner's access, and all server-enforced limits, depend on the server record alone.
- Quantity limits (memories, pending surprises), premium themes and custom accents are enforced in the database. Cosmetic items (papers, inks, stickers, drawing tools, widget styles) are gated in the client only; forging one gains nothing that costs us anything.

## Consequences
- The free tier is real: unlimited notes, drawing, photos, 4 papers, 7 inks, 6 stickers, 2 themes, 30 memories, 1 pending surprise, all widget families.
- Family Sharing is off: the couple model replaces it.
- **Verified:** StoreKit 2 purchase, pending, failure, expiry, refund and account binding against the bundled StoreKit configuration; JWS verification and state mapping with a generated certificate chain; database refusal of every client write. **Not verified:** the deployed Edge Functions and real App Store sandbox transactions (need a Supabase project and App Store Connect products).
