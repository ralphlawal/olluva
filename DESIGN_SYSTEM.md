# Design system

Source of truth: `Packages/CoupleKit/Sources/CoupleDesign`. Screens use tokens, never literals.

## Art direction: paper on a desk
The interface is a quiet page. The note is a physical object lying on it: it is the only thing with depth, it is set at a slight angle, and it is the largest thing on any screen it appears on. Everything else is typography and hairlines.

What this rules out, on purpose: gradients, glass cards stacked on cards, borders around everything, decorative hearts, illustration, emoji as icons, dashboards of counts, and motion that is not caused by the person.

## Colour
Semantic tokens (`Palette`), resolved per theme and per appearance. Light values for the default theme:

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `canvas` | `#FAF7F2` | `#16111A` | The page |
| `surface` | `#FFFFFF` | canvas +7% white | Raised content |
| `sunken` | `#F1E9DE` | `#1F1825` | Wells, secondary buttons |
| `ink` | `#28242C` | `#F3EDF5` | Text |
| `inkSecondary` | `#69636D` | `#B9AFBF` | Supporting text (5.3:1 on canvas) |
| `inkTertiary` | `#A39CA6` | `#7E7484` | Decoration and placeholders only |
| `accent` | `#302238` | `#D9C8F0` | Primary actions, selection |
| `onAccent` | white | `#1E1524` | Chosen by luminance |
| `highlight` | `#B4566A` | `#E9A9B6` | The unread mark, a chosen reaction |
| `danger` / `success` | `#B3372F` / `#3F7D5C` | `#F08A80` / `#8CCBA6` | |

The brief's `#77717A` secondary text measured 4.4:1 on the paper background, under the 4.5:1 minimum, so it was darkened to `#69636D`.

Dark appearance is its own palette, not an inversion: notes use a slightly dimmed paper tone so they do not glare, and the primary button becomes light lavender with dark text.

Six themes (`Theme.all`) each supply canvas, sunken, accent and highlight for both appearances. A custom accent is contrast-checked against the canvas and adjusted if it falls below 3:1.

## Type
System fonts only, all built on text styles so everything follows Dynamic Type.

| Token | Definition | Use |
| --- | --- | --- |
| `display` | largeTitle, serif (New York), semibold | One per screen at most |
| `title` | title, serif, semibold | Sheet and form titles |
| `heading` | title3, serif, semibold | Names, month headings |
| `body` / `bodyStrong` | body | Reading text, button labels |
| `callout` / `calloutStrong` | subheadline | Supporting text |
| `caption` | footnote | Metadata |
| `overline` | caption, semibold, uppercase, tracked | Section labels |
| `code` | title, monospaced | Invitation and confirmation codes |

Notes are written in one of three faces: handwritten (Bradley Hand, which ships with iOS), serif or rounded. Note lettering is sized in proportion to the card so a note looks the same at every size; because that cannot follow Dynamic Type, the note screen also shows the words as ordinary body text at accessibility sizes.

## Space, shape, depth
- Spacing: 4, 8, 12, 16, 24, 32, 48. Screen gutter 24.
- Radii: chip 10, field 14, card 22, paper 5 (a sheet of paper barely has a corner).
- Touch targets: 44pt minimum (`Size.touch`); primary buttons 54pt.
- Shadow: `paperShadow` for notes, `softShadow` for the two raised surfaces (invitation card, toast). Nothing else casts one.

## Motion and haptics
- `Motion.standard` (spring 0.42 / 0.86) for movement, `Motion.fade` (0.2s) for appearance, `Motion.gentle` for the launch and welcome.
- With Reduce Motion on, movement becomes a cross-fade and the skeleton stops pulsing.
- Haptics mark a meaningful change: selection in a picker, a successful send, a failure. Never decoration.

## Components
`PrimaryButtonStyle` (with in-place loading) · `SecondaryButtonStyle` · `QuietButtonStyle` · `CircleIconButtonStyle` · `LabeledField` · `AvatarView` · `NoticeBanner` (error, info, success) · `EmptyStateView` · `LoadFailureView` · `SkeletonBlock` · `ToastView` · `SectionHeading` · `Hairline` · `PremiumMark` · `NoteCardView` · `PaperNote` · `PaperPatternView`.

`NoteCardView` is the one renderer for a note. The app, the scrapbook, the composer's preview and the widgets all use it.

## States
Every data-backed screen handles: loading (skeleton in the shape of the content), empty (what this place is for and the action that starts it), error (inline, with retry where retrying can help), offline (content already loaded stays visible), and success (toast or in-place change). Errors are shown where the problem is, not in alerts.

## Icons
SF Symbols, medium weight, at 17 (inline), 20 (controls) or 28 (feature). A lock badge appears only on items that would otherwise seem to do nothing when tapped.

## Accessibility
- VoiceOver: every control has a label; notes are read as their words plus "includes a photo / drawing"; selected states use traits; sticker and crop gestures have button or adjustable alternatives.
- Dynamic Type: layouts are scroll views with wrapping text; the welcome illustration steps aside at accessibility sizes.
- Contrast: body and supporting text meet 4.5:1 in both appearances.
- Not yet done: a full manual VoiceOver pass on a device, and testing at the largest accessibility sizes on every screen.
