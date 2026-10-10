# ADR 0008: No sign-up. Anonymous identity, with Apple ID as an optional backup

Status: accepted · 2026-10-10 (owner decision). Supersedes the email and password sign-in described in earlier documents.

## Context
Asking a couple for an email, a password and a confirmation code before they can send each other a note is friction the product does not need, and it means holding email addresses we have no use for. But the server still has to know which two phones belong to a space, or it cannot keep everyone else out.

## Decision
- **"No account" means no sign-up, not no identity.** Tapping "Get started" creates an anonymous Supabase Auth user. Its session lives in the phone's Keychain. The only thing the person is asked for is a name.
- An anonymous user is a real `auth.users` row with the `authenticated` role. Every RLS policy and database function applies unchanged. No policy is relaxed for them.
- **Backup is optional and uses Sign in with Apple only.** It links the Apple identity to the existing user (`linkIdentityWithIdToken`), so the user id, the space and everything in it stay the same. No name or email scope is requested.
- Backup is offered once, on a launch after pairing, and is always available in Settings.
- **Restore** on a new phone is "I already have a space" → Sign in with Apple.
- **Sign out is offered only once backed up.** Without a backup there is no way back in, so the option is not shown.
- **Delete everything** replaces "Delete account" and does the same thing on the server.
- Email and password, confirmation codes and password reset are removed entirely.
- Identities that were created and abandoned before doing anything (anonymous, no name, never in a space, no subscription, older than 30 days) are purged daily.

## Consequences
- Onboarding is two screens: welcome, name.
- We ask for no email address. Sign in with Apple is called with no scopes, so no name or email is requested; what Apple returns in that case should be confirmed against a real token before the privacy policy states it as fact.
- **A person who never backs up and loses their phone loses their space.** Their partner's copy is unaffected, and the two can pair again, but the old space cannot be rejoined. The app says this where it matters.
- Uninstalling the app does not necessarily clear the Keychain, so a reinstall on the same phone often resumes the same identity. This is iOS behaviour and is not guaranteed.
- **Abuse:** creating identities is free. Mitigations in place are Supabase's built-in rate limit on anonymous sign-ins (per IP), the existing per-identity limits on invitations and redemption attempts, and the purge above. **Not in place:** CAPTCHA or App Attest. Add one if abuse appears; Supabase supports CAPTCHA on anonymous sign-in natively.
- One Apple ID can back up one identity. Trying to back up a second with the same Apple ID is refused with an explanation.
- Restoring with an Apple ID that has no backup creates a new, empty identity that is already backed up.

## Verification
- **Verified:** the whole flow on the in-memory backend (unit and UI tests), and that anonymous users are held to the same database rules (`accounts.test.js`, "identity without sign-up").
- **Not verified:** real anonymous sign-in and identity linking against Supabase, and Sign in with Apple itself (needs the capability on a device build and the Apple provider enabled in the project).
