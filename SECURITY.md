# Security and privacy

## Threat model in one paragraph
The content is intimate. People have no account: each phone holds an anonymous identity, optionally backed up with an Apple ID (ADR 0008). The realistic threats are: another user reading or altering a couple's data by guessing identifiers or calling the API directly; someone joining a space they were not invited to; a former partner retaining access; premium being self-granted; private text leaking through a Lock Screen, a log or shared storage; and a lost or borrowed phone. The client is assumed to be hostile: nothing below depends on the app behaving.

## Controls

| Risk | Control | Verified by |
| --- | --- | --- |
| Cross-couple read or write (IDOR) | RLS on every table keyed to active membership of the space; writes that carry rules go through `SECURITY DEFINER` functions | `supabase/tests/content.test.js`: another couple cannot read, insert, edit, delete, react to or save a note |
| Unauthorised pairing | Invitation-only; 50-bit codes stored as SHA-256; single-use; 48h expiry; revocable; accept shows who it is from first | `pairing.test.js` |
| Invitation guessing | 5 failed attempts per account per 15 minutes, recorded even when the call fails; missing and dead codes are indistinguishable; 10 invitations per account per day | `pairing.test.js` "invitation abuse" |
| Races while pairing | Per-account advisory lock, ordered row locks on the spaces involved, and a unique index as the backstop | `pairing.test.js` "under concurrency" |
| Former partner keeps access | Unlinking sets `left_at` and ends the space in one transaction; every policy requires active membership of an active space; media access ends at the same instant | `pairing.test.js`, `content.test.js` |
| Impersonating the partner | `author_id`, timestamps, version and origin are set by a trigger; those columns are not granted to clients | `content.test.js` |
| Lost updates | Version check on edit; append-only notes; client never replaces a newer version with an older one | `content.test.js`, `NoteFeedTests`, `NotesStoreTests` |
| Duplicate sends and deliveries | Client-generated ids; idempotent insert; scheduled note reuses the message id; `SKIP LOCKED` workers | `content.test.js`, `LocalBackendTests`, `NotesStoreTests` |
| Self-granted premium | No client write path to `subscriptions`; purchases verified against Apple's chain on the server; limits enforced in SQL | `accounts.test.js`, `functions.test.js` (the client-side `PurchaseStoreTests` need a signing team and have not run) |
| Cross-couple media access | Storage policies parse the path and require membership; malformed or traversal-style names fail closed; uploads are write-once | `content.test.js` "private media" |
| Malicious uploads | Bucket MIME allow-list and size limits; the app re-encodes every image, which also strips EXIF including location | `ImagePipelineTests` |
| Device tokens as a credential | Tokens are never an input to authorisation, are not readable through the API, move with the signed-in account and are removed on sign-out | `accounts.test.js` |
| Private text on a Lock Screen | Notification previews and Lock Screen widget text are off by default; the outbox stores ids only | `accounts.test.js`, `WidgetSnapshotTests`, `functions.test.js` |
| Secrets in the app | Only the public anon key is in the app. The service-role key, APNs key and cron secret exist only as Edge Function secrets | Code review; `.gitignore` |
| Transport | The backend URL is built as `https://` + host; a host containing a scheme or path is rejected | `ConfigurationTests` |
| Unauthenticated access | The `anon` role (no identity at all) can read no table and call no function | `pairing.test.js` "anonymous access" |
| Anonymous identities over-reaching | They are ordinary authenticated users: same policies, no exceptions | `accounts.test.js` "identity without sign-up" |
| Taking over a space through backup | An Apple ID can be linked to one identity only; linking is done by Supabase Auth from an Apple-signed token | `LocalBackendTests`; not yet tested against Supabase |
| Data on the device | Session in the Keychain (SDK default). Caches, outbox, drafts and the widget snapshot use file protection until first unlock, and are wiped on sign-out, unlink and deletion. The invitation code is kept in the Keychain, this device only. | `NotesStoreTests`, `WidgetSnapshotTests` |
| Logs | App and function logs carry event names and codes only. `Diagnostics` and `log()` take no user content. | Code review |

## What is not claimed
- **No end-to-end encryption.** Supabase staff with database access, and anyone who compromised the project, could read content. See ADR 0007. The app says so in its privacy explainer.
- **Invitation hashes are fast hashes.** A leaked database would allow offline guessing of unexpired codes (50 bits, 48 hours). Accepted for the convenience of short codes.
- **Identities are free to create.** Limits on invitations and redemption attempts are per identity, so someone willing to create many identities gets many attempts. What stands in the way is Supabase's per-IP rate limit on anonymous sign-ins and the 50-bit, 48-hour codes. There is no CAPTCHA or App Attest yet; add one if abuse appears.
- **No recovery without a backup.** A person who has not attached their Apple ID and loses their phone cannot get back into their space. Nobody else can either.
- **No certificate pinning.** Standard system trust is used.
- **No screenshot or screen-recording protection.**
- **No jailbreak detection.**

## Account deletion and export
- Export: `export_my_data()` returns everything the caller authored as JSON, including from spaces that have ended. It never includes the partner's content. Media files are referenced by path, not embedded.
- Deletion ("Delete everything"): the `delete-account` function identifies the caller from their token only, runs `prepare_account_deletion` (ends the space, deletes authored notes, memories and surprises, queues media), then deletes the auth user; foreign keys cascade the rest. Deleting an account does not cancel an App Store subscription, and the app says so.

## Verified against the hosted project (10 October 2026)
`supabase/tests/live-check.mjs` attacks the deployed project through its public API using only the publishable key: 36 checks, all passing. It covers anonymous sign-in, pairing, cross-couple reads and writes, impersonation, server-only columns and functions, self-granted subscriptions, and the real Storage API (cross-couple download and upload, public access, overwrite, client delete, non-image upload, access after unlinking). The app's own client passes `CoupleSupabaseLiveTests` against the same project, including Realtime delivery.

### One behaviour to know about: the CDN
Supabase's CDN keeps a copy of a private file for the exact session that already downloaded it. So after unlinking, a person can keep fetching, by its unchanged URL, a photo **they had already downloaded**, until their access token expires (at most an hour). Nobody else can: a partner who had not fetched it, another couple and an unauthenticated caller are all refused, and any request that reaches Storage itself is refused. The person already had those bytes, so nothing new is exposed, but revocation of media is not instantaneous at the edge. Deleting the object (the purge worker) invalidates the cached copy.

## Not yet verified
The Supabase Security Advisor has not been run on the project. The Edge Functions are not deployed, so purchase verification, push delivery, storage purge and account deletion have not run for real. Sign in with Apple backup and restore have not been exercised against Apple.

## Reporting a vulnerability
Add a security contact before launch (placeholder: security@example.com).
