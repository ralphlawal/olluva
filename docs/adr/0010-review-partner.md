# ADR 0010: A demo partner for App Review

Date: 11 October 2026 · Status: accepted

## Context
Everything past the first two screens needs a second person. An App Store reviewer has one phone, and an app they cannot get into is rejected. Demo mode exists only in Debug builds, by design.

## Decision
One invitation code, given to Apple in the review notes, is kept permanently redeemable. Behind it waits a "Demo Partner" identity alone in a space of its own. The reviewer redeems the code through the ordinary pairing flow, which is unchanged and has no special case. The demo partner greets them and answers each note.

A worker (`review-partner`, run by triggers and every five minutes) creates the next demo partner when the last has been paired with, writes the replies, and deletes demo partners after 14 days or as soon as the other person leaves.

## Why this is acceptable
- A demo partner is a separate identity in a separate space. The code gives access to that space only.
- Nobody holds a demo partner's session; it cannot sign in.
- The code is an Edge Function secret (`REVIEW_INVITE_CODE`). Only its hash is stored, like any invitation. It is not in this repository. Unsetting the secret retires it.
- Bounded: at most 30 demo partners a day and 25 replies per space.
- It never takes over a code a real person holds.

## Cost
Anyone who learns the code can create demo spaces up to the daily allowance. That exposes nothing, and the code can be rotated by changing the secret. The partner's name says plainly that it is a demo, so nobody who stumbles on it is misled.

## Alternatives rejected
- **Demo mode in Release builds**: ships a fake backend to every user and breaks the rule that release builds never simulate.
- **A video in the review notes**: no code, but reviewers generally want to use the app themselves.
