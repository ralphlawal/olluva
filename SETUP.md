# Setup

## 1. Tools
- Xcode 26 or later (built with 26.5), with an iOS 17+ simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node 22+ (only for the backend tests)
- Supabase CLI (only to deploy the backend): `brew install supabase/tap/supabase`

## 2. Run the app with no backend (demo mode)
```sh
xcodegen generate
open CoupleNotes.xcodeproj      # run the CoupleNotes scheme
```
With no Supabase settings, a **Debug** build runs on an in-memory demo backend and says so on screen. Nothing is saved or sent. Choose a starting point with the launch argument `-demoScenario <name>`:

| Scenario | Starts as |
| --- | --- |
| `fresh` (default) | First launch. A demo partner is waiting with code `SAMSAM2345`. |
| `solo` | Started and named, not paired |
| `empty` | Paired, nothing written |
| `paired` | Paired, with notes, memories and dates |
| `premium` | As `paired`, with a premium partner |

A **Release** build with no backend shows a "not connected to a server" screen. It never falls back to demo data.

From the command line: `scripts/build.sh` builds for the simulator and `scripts/run_sim.sh -demoScenario paired` installs and launches. Build output is kept outside the project folder on purpose: `codesign` rejects products built inside folders that Finder decorates with extended attributes (Desktop, Documents, iCloud Drive).

## 3. Identity and signing
Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` (git-ignored) and set:

| Setting | Example |
| --- | --- |
| `DEVELOPMENT_TEAM` | your 10-character team id |
| `APP_BUNDLE_ID` | `com.yourcompany.yourapp` |
| `APP_GROUP_ID` | `group.com.yourcompany.yourapp` |
| `SUPABASE_HOST` | `abcd1234.supabase.co` (host only, no `https://`) |
| `SUPABASE_ANON_KEY` | the project's anon (publishable) key |

`APP_DISPLAY_NAME`, version and build number are in `Config/Shared.xcconfig`. Run `xcodegen generate` after changing any of these.

In the Apple Developer portal, register:
1. App ID `APP_BUNDLE_ID` with **App Groups**, **Push Notifications**, **Sign in with Apple**.
2. App ID `APP_BUNDLE_ID.widgets` with **App Groups**.
3. App Group `APP_GROUP_ID`, assigned to both.

With automatic signing, Xcode creates the profiles. The targets and their entitlements:

| Target | Bundle id | Entitlements |
| --- | --- | --- |
| `CoupleNotes` | `$(APP_BUNDLE_ID)` | App Group, `aps-environment`, Sign in with Apple |
| `CoupleNotesWidgets` | `$(APP_BUNDLE_ID).widgets` | App Group |

The widget finds the shared container through `AppGroupID` in its Info.plist, which is filled from `APP_GROUP_ID`. If the two targets do not share the same group, the widget shows its placeholder forever.

## 4. Supabase
> Creating a project may incur cost depending on your plan. Nothing in this repository creates infrastructure by itself.

```sh
supabase link --project-ref <ref>
supabase db push                       # applies supabase/migrations
```

Then, in the dashboard:

1. **Database → Extensions**: `pg_cron` and `pg_net` are enabled by the first migration, and the jobs below are created by later ones. Check they exist with `select jobname from cron.job;`. If any are missing, run:
   ```sql
   select cron.schedule('deliver-scheduled-messages', '* * * * *', 'select app_private.deliver_due_scheduled_messages()');
   select cron.schedule('enqueue-date-reminders', '5 * * * *', 'select app_private.enqueue_date_reminders()');
   select cron.schedule('queue-orphaned-uploads', '20 3 * * *', 'select app_private.queue_orphaned_uploads()');
   select cron.schedule('purge-ended-spaces', '40 3 * * *', 'select app_private.purge_ended_spaces()');
   select cron.schedule('purge-abandoned-identities', '0 4 * * *', 'select app_private.purge_abandoned_identities()');
   ```
2. **Authentication → Sign In / Providers**: turn on **Allow anonymous sign-ins**. This is what "Get started" uses; without it the app cannot create an identity. Email sign-in is not used and can be turned off.
3. **Authentication → Providers → Apple**: enable, and add `APP_BUNDLE_ID` as a client id (native sign-in needs no secret). Also enable **manual identity linking** (Authentication → Sign In / Providers → "Allow manual linking"), which backing up relies on.
4. **Authentication → Rate limits**: review the limit on anonymous sign-ins. **Attack protection**: consider CAPTCHA for anonymous sign-ins if abuse appears (ADR 0008).
5. **Database → Publications**: confirm `supabase_realtime` includes the tables listed in DATABASE_SCHEMA.md.
6. Run the **Security Advisor** and resolve anything it reports.

### Edge Functions
```sh
cp .env.example .env        # fill in; see comments in the file
supabase secrets set --env-file .env
for f in delete-account verify-purchase app-store-notifications send-push purge-storage; do
  supabase functions deploy $f --use-api --no-verify-jwt
done
```
All five are deployed with `--no-verify-jwt`: projects using the new API keys sign user tokens asymmetrically, which the gateway's built-in check does not cover. Each function authenticates its caller itself (the user's token via Supabase Auth, Apple's signature, or the `CRON_SECRET` header).

Tell the database where the functions live and what secret to present (run once, in the SQL editor):
```sql
select vault.create_secret('https://<ref>.supabase.co', 'project_url');
select vault.create_secret('<the CRON_SECRET value>', 'cron_secret');
```
With those two Vault entries in place, the migrations do the rest: a trigger calls `send-push` the moment a notification is queued, a sweep retries every minute, and `purge-storage` runs hourly.

## 5. Push notifications
1. Apple Developer → Keys: create a key with **APNs**. Put its id, your team id and the `.p8` contents in `.env` (`APNS_*`).
2. Debug builds register sandbox tokens, Release builds production tokens (`APS_ENVIRONMENT` in the xcconfig files); the server picks the APNs host per token.
3. Push delivery needs a real device.

## 6. In-app purchases
1. App Store Connect → Subscriptions: create group `premium` with a yearly and a monthly product. Turn Family Sharing off.
2. Put the two product ids in `ProductConfiguration` (`Catalog.swift`), in `App/Resources/Products.storekit`, and in `APPLE_PRODUCT_IDS`.
3. App Store Connect → App Information → **App Store Server Notifications**: set the Production and Sandbox URLs to `https://<ref>.supabase.co/functions/v1/app-store-notifications` (Version 2).
4. For a development or TestFlight Supabase project set `APPLE_ALLOW_SANDBOX=true`. Leave it unset in production.
5. Local testing without App Store Connect: the `CoupleNotes` scheme already uses `Products.storekit`.

## 7. Environments
Use two Supabase projects (development, production), each with its own secrets, and select between them with `Config/Secrets.xcconfig` or a per-configuration xcconfig. Never point a TestFlight build with `APPLE_ALLOW_SANDBOX=true` at production data.

## Required configuration at a glance
| Where | Values |
| --- | --- |
| `Config/Secrets.xcconfig` | `DEVELOPMENT_TEAM`, `APP_BUNDLE_ID`, `APP_GROUP_ID`, `SUPABASE_HOST`, `SUPABASE_ANON_KEY` |
| Edge Function secrets | `APPLE_BUNDLE_ID`, `APPLE_PRODUCT_IDS`, `APPLE_ALLOW_SANDBOX`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `CRON_SECRET` |
| Supabase Vault | `cron_secret` |
| Source | Product ids in `Catalog.swift` and `Products.storekit`; links in `AppLinks` (`SettingsView.swift`) |
