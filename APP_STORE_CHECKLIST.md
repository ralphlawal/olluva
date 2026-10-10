# App Store and TestFlight checklist

Status key: ✅ done in this repository · ⏳ needs the owner (account access, a decision, or a device) · ◻️ not started

Nothing here has been submitted. The app is not published or approved.

## Identity and build
- ⏳ Final product name, checked for trademark and App Store availability (working title: "Dearly")
- ⏳ Bundle id, App Group id, team id in `Config/Secrets.xcconfig`
- ✅ Display name, version (`0.1.0`) and build number driven from xcconfig
- ✅ App icon, 1024×1024, no alpha (`scripts/make_app_icon.swift` regenerates it). Treat as a placeholder until a designer has reviewed it; add dark and tinted variants.
- ✅ Launch screen (background colour matching the first frame, light and dark) and in-app launch animation
- ✅ Portrait only, iPhone only
- ✅ `ITSAppUsesNonExemptEncryption = false` (only standard HTTPS/TLS is used). Confirm with whoever handles export compliance.
- ✅ Privacy manifest (`PrivacyInfo.xcprivacy`): no tracking; UserDefaults and file-timestamp reasons declared
- ⏳ Check the privacy manifests of `supabase-swift` and its dependencies in the archive's privacy report

## Capabilities
- ✅ App Groups (app and widget), Push Notifications, Sign in with Apple, Background Modes → Remote notifications: declared in entitlements and Info.plist
- ⏳ The same capabilities enabled on both App IDs in the developer portal
- ⏳ APNs key created and stored as Edge Function secrets
- ⏳ Universal Links (optional): needs a domain and an `apple-app-site-association` file. Today invitations use the `couplenotes://` scheme.

## Backend
- ⏳ Production Supabase project created; migrations applied; `pg_cron` and `pg_net` enabled; jobs scheduled
- ⏳ Edge Functions deployed and secrets set (SETUP.md §4)
- ⏳ Email templates send a 6-digit code
- ⏳ Cross-couple access re-tested through the real API (SECURITY.md "Not yet verified")
- ⏳ Supabase Security Advisor clean
- ⏳ Backups and point-in-time recovery chosen for the plan

## In-app purchases
- ⏳ Subscription group and two products created; localised names and descriptions; Family Sharing off
- ⏳ Prices chosen (the values in `Products.storekit` are test fixtures, not a decision)
- ⏳ Product ids updated in `Catalog.swift`, `Products.storekit`, `APPLE_PRODUCT_IDS`
- ⏳ App Store Server Notifications V2 URLs set (production and sandbox)
- ⏳ Sandbox purchase, renewal, expiry, refund and restore tested end to end, including the partner's device unlocking
- ✅ Paywall shows price, period, renewal terms, restore, Terms and Privacy links, and a close button
- ⏳ Subscription review screenshot and review notes

### Subscription metadata to prepare
Group display name · per product: reference name, display name (≤ 30), description (≤ 45), price, duration · a 1024×1024 promotional image (optional) · review screenshot of the paywall.

## Legal and support
- ⏳ Privacy Policy URL (required). Must cover: account data, notes/photos/drawings, device tokens, purchase records, Supabase as processor, retention (30 days after unlinking), deletion and export.
- ⏳ Terms of Use (EULA) URL, or use Apple's standard EULA and say so in the description
- ⏳ Support URL and contact email (`AppLinks` in `SettingsView.swift` points at example.com)
- ✅ In-app account deletion (Settings → Delete account), required by guideline 5.1.1(v)
- ✅ In-app data export

## App Privacy questionnaire (based on what the code actually does)
Data is **not** used for tracking. No third-party analytics or advertising SDKs are included.

| Data type | Collected | Linked to the user | Purpose |
| --- | --- | --- | --- |
| Email address | Yes | Yes | App functionality (account) |
| Name | Yes (display name) | Yes | App functionality |
| User ID | Yes | Yes | App functionality |
| Photos | Yes (only those a person attaches) | Yes | App functionality |
| Other user content | Yes (notes, drawings, captions, dates) | Yes | App functionality |
| Device ID | Yes (APNs token) | Yes | App functionality (notifications) |
| Purchase history | Yes (subscription status) | Yes | App functionality |
| Location, contacts, health, browsing, search, diagnostics, advertising data | No | | |

Re-check this table whenever a dependency or an analytics tool is added. If crash reporting is added, declare Diagnostics.

## Age rating
Answer "None" to all content categories. Declare **unrestricted user-generated content: No public sharing**; the app is a private two-person space. Expected rating: 4+ (or the equivalent in the current questionnaire). Under-13 use is not targeted; state the minimum age in the Terms.

## Review notes (draft)
> Dearly is a private space for two people. To review it you need two accounts that are paired.
> Demo accounts: `<reviewer-a@…>` / `<password>` and `<reviewer-b@…>` / `<password>`, already paired with sample content.
> To see pairing from scratch: create a new account, choose "Invite my partner", then sign in on a second device with a second account and enter the code.
> Widgets: add "Latest note" from the widget gallery. iOS schedules widget refreshes; opening the app always refreshes it.
> Premium: one subscription unlocks premium for both members of a space. The partner's access is granted by our server after it verifies the transaction with Apple.
> Account deletion: Settings → Delete account.

## Listing
- ⏳ Name (≤ 30), subtitle (≤ 30), keywords (≤ 100), category: Lifestyle (secondary: Social Networking)
- ✅ Description draft below
- ⏳ Screenshots: required 6.9" (1320 × 2868) and 6.5" (1284 × 2778 or 1242 × 2688), portrait. Capture from the real app in the `paired` demo scenario or from a staging account: Home, composer, a photo note, Memories, widgets on a Home Screen, pairing. Screenshots must show real screens; do not composite features that do not exist. A widget-on-Home-Screen shot needs a device or simulator Home Screen, captured by hand.
- ⏳ App preview video (optional)

### Description (draft)
> Make your favourite person part of your everyday.
>
> Dearly is a private space for the two of you. Leave each other notes, drawings and photos, and see them appear on each other's Home Screen.
>
> • Write, draw or send a photo on a note that looks the way you want it to
> • Put the latest note on your Home Screen or Lock Screen with a widget
> • Plan a surprise: write a note now and have it arrive later
> • Keep the ones that matter in a shared scrapbook
> • Remember anniversaries and birthdays together, or keep a date secret while you plan
> • Choose a look for your space
>
> Private by design. Your space has exactly two members. Notifications and Lock Screen widgets don't show what a note says unless you choose to turn that on. You can export what you've written or delete your account at any time.
>
> Premium is optional, and one subscription covers you both.

## Accessibility review before submission
- ⏳ Full VoiceOver pass on a device: onboarding, pairing, composer (including drawing and stickers), note detail, settings
- ⏳ Largest Dynamic Type size on every screen
- ⏳ Reduce Motion, Increase Contrast, Bold Text, Differentiate Without Colour
- ✅ Labels, traits and identifiers on controls; gesture alternatives for crop and stickers; 44pt targets; contrast-checked palette

## TestFlight
1. Fill in `Config/Secrets.xcconfig`; `xcodegen generate`.
2. Xcode → Product → Archive (Release configuration; `aps-environment` becomes `production`).
3. Validate, then upload. Wait for processing.
4. App Store Connect → TestFlight: add "What to test"; add internal testers. External testing needs Beta App Review and the privacy policy URL.
5. Test on real devices, in this order: sign-up and email code → pairing with two phones → send text, drawing and photo notes → widget appears and updates → push arrives (previews off, then on) → schedule a surprise for five minutes ahead and lock both phones → sandbox purchase on one phone unlocks the other → refund in sandbox removes it → unlink → delete account.
6. Watch Edge Function logs and the `notification_outbox` and `storage_purge_queue` tables during the test.
