# ADR 0011: Together, a daily question answered apart and opened together

Date: 13 October 2026 · Status: accepted

## Context
Notes are sent when someone has something to say. A daily question gives a couple a reason to write on the days they do not, and the pleasure of it is in the reveal: each answers alone, and they read both at once. That only works if neither can see the other's answer early, by any route.

## Decision

**The reveal rule lives on the server.** Answers are in `together_answers`, on which `anon` and `authenticated` hold no privileges and which has no policies. Nothing the app could send to the API reads that table. Every read and write goes through `SECURITY DEFINER` functions, and one helper, `app_private.together_state`, builds what a person may see: their own answer always; whether the partner has answered; the partner's answer only once `revealed_at` is set. A SwiftUI condition is not part of the protection, and the client never holds an unrevealed answer to hide.

**`together_moments` is readable by the couple** so that Realtime can tell the other phone something changed. It carries no answer text: the question id, how many have answered, and when it was revealed.

**One moment per couple per day**, enforced by a unique key. The day is reckoned in a time zone fixed for the couple the first time either of them opens the feature, so two partners in different zones never disagree about which day it is. A plain UTC day was rejected because it changes in the afternoon or evening for much of the world.

**The question is chosen on the server**, deterministically from the couple, the day and what they were asked before: nothing from their last sixty moments, and a different category from the day before while unused questions allow it. Both partners arriving at once pick the same question, and the unique key lets only one of them create the row. The library is a table of 72 curated questions in six categories. No external service is involved.

**Reveal is one event for both.** Either person may open a moment once both answers are in. The row is locked while answering and revealing, so two simultaneous answers, two simultaneous reveals, or an edit racing a reveal all leave one consistent state. Revealing twice is harmless. Each phone plays its own opening animation once, whoever did the opening.

**Missed days are left behind.** A day both people did not finish is not shown in the history, is not chased, and cannot be answered late; what one person wrote stays private to them. A day both answered but never opened stays ready to open. There are no streaks and no counts of days missed.

**Notifications say that something happened, never what was written**: your partner answered; both answers are in; and, once a morning at about nine in the couple's time, that there is a new question, sent only to couples who answered one in the last week. Each has its own preference.

**Memories.** A revealed moment can be saved to the scrapbook as an ordinary `moment` memory holding the question, linked by `memories.together_moment_id` (unique). The answers are not copied into it, so removing the memory removes nothing else, and an older version of the app shows it as a normal memory.

## Lifecycle
Unlinking closes the moments to both people at once, like everything else in a space; they are erased with the space after thirty days. Deleting an account erases that person's answers and leaves their partner's. "Export my data" includes the person's own answers and never their partner's.

## Consequences
- The feature needs the server: there is no offline answering beyond a draft kept on the phone, which is never treated as an answer.
- The question library is English only and lives in the database; adding or retiring questions is a migration, not an app release.
- Operators with database access can read answers, as with all content (ADR 0007).

## Alternatives rejected
- **RLS policies on the answers table that hide the partner's row until reveal.** Workable, but then correctness depends on every future policy and view being right. No grant is simpler to reason about and to test.
- **Choosing the question on each phone from the date.** Simple, but two phones in different time zones, or on different app versions with different lists, would disagree.
- **Carrying an unanswered question forward until both answer.** Kinder on the face of it, but one person not answering would freeze the feature for both.
