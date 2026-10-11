# App Store listing (draft)

Draft text and answers for App Store Connect. Nothing here has been entered yet. Character counts are checked against Apple's limits.

## Text

**Name** (30 max): `Olluva`

**Subtitle** (30 max): `A private space for two`

**Promotional text** (170 max, can be changed without review):
`Leave each other notes, drawings and photos, and see them appear on each other's Home Screen. No account needed.`

**Keywords** (100 max): `couple,widget,love,notes,partner,relationship,long distance,girlfriend,boyfriend,memories,draw,ldr`

**Description**

```
Olluva is a private space for you and one other person.

Write a note, draw something, or send a photo. It appears on their Home Screen, on a widget, without them opening anything. They can do the same for you.

NOTES THAT LOOK THE WAY YOU MEAN THEM
• Write, draw with your finger, or send a photo
• Choose the paper, the ink and the handwriting
• Add stickers, or start from a template for a birthday or an anniversary

RIGHT ON THE HOME SCREEN
• Small, medium and large Home Screen widgets
• Lock Screen widgets that say a note is waiting, without showing what it says
• The widget updates within moments of a note being sent

SURPRISES, ON TIME
• Write a note now and have it arrive later, even if your phone is off

KEEP WHAT MATTERS
• Save the notes you love to a shared scrapbook
• Add your own moments with a photo and a date
• Remember important dates, with a reminder on the morning

NO ACCOUNT NEEDED
• No email, no password. Type your name and invite your person with a code
• Back up your space with your Apple ID if you want to keep it when you change phones

PRIVATE BY DESIGN
• A space has exactly two people. Nobody else can read it through the app
• Notifications say who wrote to you, not what they wrote, unless you turn previews on
• No ads, no tracking
• Export what you've written, or delete everything, at any time

OLLUVA PREMIUM
Olluva is free to use. Premium adds more themes and your own accent colour, every paper, ink and sticker, more drawing tools, extra widget styles, a much bigger scrapbook, and more surprises waiting at once. One subscription covers both of you.

Premium is an auto-renewing subscription, monthly or yearly. Payment is charged to your Apple ID at confirmation of purchase. It renews automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel in your Apple ID settings.

Terms: https://ralphlawal.github.io/olluva/terms/
Privacy: https://ralphlawal.github.io/olluva/privacy/
```

## App information

| Field | Value |
| --- | --- |
| Primary category | Lifestyle |
| Secondary category | Social Networking |
| Content rights | Does not contain third-party content |
| Privacy Policy URL | https://ralphlawal.github.io/olluva/privacy/ |
| Support URL | https://ralphlawal.github.io/olluva/support/ |
| Marketing URL | https://ralphlawal.github.io/olluva/ |
| Copyright | 2026, followed by your legal name |

Replace the three URLs with the olluva.app ones once the domain works.

## Age rating questionnaire

Answer **None** or **No** to every content question (violence, sexual content, profanity, drugs, gambling, horror, medical, contests) and to web access, advertising and "made for kids". Two capability questions need a **Yes**:

- **Messaging and chat:** yes. Two paired people exchange notes, drawings and photos.
- **User-generated content:** yes, shared only between those two people.

Apple calculates the rating from these answers.

## App Privacy ("nutrition label")

Tracking: **No**. For every item below: used for **App Functionality** only, **linked to the user**, **not used for tracking**.

| Data type | What it is in Olluva |
| --- | --- |
| Contact Info → Name | The display name the person types |
| Contact Info → Email Address | Only if someone backs up with Sign in with Apple and Apple includes an address in what it returns. Declared to be safe |
| User Content → Photos or Videos | Photos sent in notes, and profile pictures |
| User Content → Other User Content | Notes, drawings, reactions, memories, dates |
| Identifiers → User ID | The anonymous identity |
| Purchases → Purchase History | Subscription status |

Not collected: location, contacts, browsing or search history, health, financial information, diagnostics, usage data, advertising data.

## Screenshots

Six images, each a headline over the app shown in a phone, in `store-screenshots/6.3-inch/` (1206 × 2622, the size App Store Connect's "iPhone with Dynamic Island (medium display)" slot takes) and `store-screenshots/6.9-inch/` (1320 × 2868). Upload them in file-name order.

1. Little notes from your person
2. Right on their Home Screen (the widgets)
3. Say it your way
4. Or just draw it
5. Keep the ones you love
6. Never miss a date that matters

They are built by `scripts/make_store_screenshots.swift` from the plain captures in `store-screenshots/raw/`, which come from the UI tests with sample data.

## What is left before submitting

**Already done, nothing for you to do**

- The 1.0 build is uploaded to App Store Connect (build 3).
- Apple's reviewer can use the app on one phone: they enter a code and get paired with a demo partner.

**For you to do in App Store Connect**

1. Paste the review notes. Open `olluva-review-notes.txt` on your Desktop, copy everything, and paste it into **App Review Information → Notes** on the 1.0 page. It tells the reviewer the code to enter.
2. Give each subscription a screenshot. In **Subscriptions → Olluva Premium**, open each of the two products and upload `olluva-premium-review-screenshot.png` from your Desktop under **Review Information**. Apple will not review a subscription without one.

**Not required by Apple, but still open**

3. A lawyer has not read the privacy policy or the terms. They describe the app accurately, but they are drafts.
4. hello@olluva.app cannot receive mail, because the olluva.app domain is suspended. People who write to it get a bounce.
