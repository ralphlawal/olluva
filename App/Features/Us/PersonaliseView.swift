import CoupleDesign
import CoupleDomain
import CoupleWidgetUI
import SwiftUI

// Screen: Personalise
// Purpose: choose how the shared space, and its widgets, look.
// Primary action: apply a theme to the space (for both partners).
// Layouts weighed: a list of theme names (you cannot judge a palette from a
// word), a carousel of full-screen previews (slow to compare), and swatch
// tiles with the whole sheet re-theming live as you tap. The live preview is
// used: nothing is changed for your partner until you press Apply.
struct PersonaliseView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var themeID = Theme.defaultID
    @State private var accentHex: String?
    @State private var action = ActionState()
    @State private var loaded = false

    var body: some View {
        // Everything inside previews the selection; the app behind is untouched.
        PersonaliseContent(themeID: $themeID, accentHex: $accentHex, action: action, apply: apply)
            .coupleTheme(themeID, accentHex: accentHex)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                themeID = app.session.space.space?.themeID ?? Theme.defaultID
                accentHex = app.session.space.space?.accentHex
            }
    }

    private func apply() {
        let theme = Theme.find(themeID)
        guard EntitlementRules.canUse(theme, with: app.entitlement),
              accentHex == nil || EntitlementRules.canUseCustomAccent(with: app.entitlement)
        else {
            app.router.isShowingPaywall = true
            return
        }
        action.run({
            try await app.backend.couples.setTheme(id: themeID, accentHex: accentHex)
            await app.session.refresh()
        }, onSuccess: {
            Haptics.success()
            dismiss()
        })
    }
}

private struct PersonaliseContent: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Binding var themeID: String
    @Binding var accentHex: String?
    let action: ActionState
    let apply: () -> Void
    @State private var showingWidgetHelp = false

    private var hasChanges: Bool {
        themeID != (app.session.space.space?.themeID ?? Theme.defaultID) || accentHex != app.session.space.space?.accentHex
    }

    private var sampleSnapshot: WidgetSnapshot {
        var snapshot = app.widgets.snapshot(session: app.session, notes: app.notes)
        snapshot.themeID = themeID
        snapshot.accentHex = accentHex
        if snapshot.note == nil {
            snapshot.state = .note
            snapshot.note = .init(
                id: UUID(), content: NoteContent(body: String(localized: "Thinking of you"), style: NoteStyle(paper: "blush", ink: "rose")),
                createdAt: Date(), isUnseen: true
            )
        }
        return snapshot
    }

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Your space")
                            .font(Typo.title)
                            .foregroundStyle(palette.ink)
                        Text("A theme changes the look for both of you. Tap one to try it on; nothing changes for \(app.session.partner?.displayName ?? "your partner") until you apply it.")
                            .font(Typo.callout)
                            .foregroundStyle(palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    themes
                    accent

                    if let error = action.error { NoticeBanner(error.message) }

                    Button("Apply to our space", action: apply)
                        .buttonStyle(.primary(isLoading: action.isRunning))
                        .disabled(!hasChanges || action.isRunning)
                        .accessibilityIdentifier("personalise.apply")

                    widgetSection(settings: settings)
                    appearance(settings: settings)
                }
                .padding(Space.gutter)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("personalise.done")
                }
            }
            .sheet(isPresented: $showingWidgetHelp) { WidgetHelpView() }
        }
    }

    private var themes: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeading("Theme")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.sm)], spacing: Space.sm) {
                ForEach(Theme.all) { theme in
                    let locked = !EntitlementRules.canUse(theme, with: app.entitlement)
                    Button {
                        Haptics.selection()
                        withAnimation(Motion.fade) { themeID = theme.id }
                    } label: {
                        ThemeTile(theme: theme, isSelected: themeID == theme.id, isLocked: locked)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(theme.title))
                    .accessibilityValue(locked ? Text("Premium") : Text(""))
                    .accessibilityAddTraits(themeID == theme.id ? .isSelected : [])
                    .accessibilityIdentifier("theme.\(theme.id)")
                }
            }
        }
    }

    private var accent: some View {
        let unlocked = EntitlementRules.canUseCustomAccent(with: app.entitlement)
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeading("Accent colour") { if !unlocked { PremiumMark() } }
            HStack(spacing: Space.xs) {
                accentButton(nil, label: "Theme default")
                ForEach(["#B4566A", "#7A5CC2", "#2F5D8A", "#3F7D5C", "#B5573A", "#A8842C"], id: \.self) { hex in
                    accentButton(hex, label: "Custom accent")
                }
            }
        }
    }

    private func accentButton(_ hex: String?, label: LocalizedStringKey) -> some View {
        let selected = accentHex == hex
        return Button {
            Haptics.selection()
            accentHex = hex
        } label: {
            ZStack {
                if let hex {
                    Circle().fill(Color(hex: hex))
                } else {
                    Circle().fill(palette.sunken)
                    Image(systemName: "circle.slash").font(.system(size: 14)).foregroundStyle(palette.inkSecondary)
                }
            }
            .frame(width: 30, height: 30)
            .padding(5)
            .overlay(Circle().strokeBorder(selected ? palette.accent : .clear, lineWidth: 2))
            .frame(width: Size.touch, height: Size.touch)
        }
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func widgetSection(settings: LocalSettings) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeading("Widget")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.md) {
                    ForEach(WidgetStyle.allCases, id: \.self) { style in
                        let locked = !EntitlementRules.canUse(style, with: app.entitlement)
                        Button {
                            if locked {
                                app.router.isShowingPaywall = true
                            } else {
                                Haptics.selection()
                                settings.widgetStyle = style
                                app.publishWidget()
                            }
                        } label: {
                            VStack(spacing: Space.xs) {
                                SmallNoteWidgetView(snapshot: styled(style))
                                    .frame(width: 112, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                                            .strokeBorder(settings.widgetStyle == style ? palette.accent : palette.hairline, lineWidth: settings.widgetStyle == style ? 2.5 : 1)
                                    )
                                    .overlay(alignment: .topTrailing) { if locked { PremiumMark().padding(6) } }
                                Text(style.title).font(Typo.caption.weight(.semibold)).foregroundStyle(palette.ink)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(settings.widgetStyle == style ? .isSelected : [])
                        .accessibilityIdentifier("widgetStyle.\(style.rawValue)")
                    }
                }
                .padding(.vertical, Space.xxs)
            }

            Toggle(isOn: $settings.hidesContentOnLockScreen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide note text on the Lock Screen").font(Typo.body).foregroundStyle(palette.ink)
                    Text("Lock Screen widgets will only say that a note is waiting.")
                        .font(Typo.caption).foregroundStyle(palette.inkSecondary)
                }
            }
            .onChange(of: settings.hidesContentOnLockScreen) { _, _ in app.publishWidget() }
            .accessibilityIdentifier("personalise.hideLockScreen")

            Button("How to add the widget") { showingWidgetHelp = true }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("personalise.widgetHelp")
        }
    }

    private func styled(_ style: WidgetStyle) -> WidgetSnapshot {
        var snapshot = sampleSnapshot
        snapshot.style = style
        // Tiles are illustrations; they never need the note's own images.
        snapshot.note?.content.photoPath = nil
        snapshot.note?.content.drawingPath = nil
        if snapshot.note?.content.body.isEmpty == true { snapshot.note?.content.body = String(localized: "Thinking of you") }
        return snapshot
    }

    private func appearance(settings: LocalSettings) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeading("Appearance on this phone")
            Picker("Appearance", selection: $settings.appearance) {
                Text("Automatic").tag(LocalSettings.Appearance.system)
                Text("Light").tag(LocalSettings.Appearance.light)
                Text("Dark").tag(LocalSettings.Appearance.dark)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("personalise.appearance")
        }
    }
}

struct ThemeTile: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette
    let theme: Theme
    let isSelected: Bool
    let isLocked: Bool

    var body: some View {
        let preview = Palette(theme: theme, scheme: scheme)
        VStack(spacing: Space.xs) {
            ZStack {
                preview.canvas
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#FFF9EC")).frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                        .rotationEffect(.degrees(-4))
                    Capsule().fill(preview.accent).frame(width: 44, height: 10)
                }
                Circle().fill(preview.highlight).frame(width: 8, height: 8).offset(x: 26, y: -30)
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .strokeBorder(isSelected ? palette.accent : palette.hairline, lineWidth: isSelected ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) { if isLocked { PremiumMark().padding(6) } }
            Text(theme.title)
                .font(Typo.caption.weight(.semibold))
                .foregroundStyle(palette.ink)
        }
    }
}

extension Theme {
    var title: LocalizedStringKey {
        switch id {
        case "paper": "Paper"
        case "plum": "Plum"
        case "linen": "Linen"
        case "dusk": "Dusk"
        case "sage": "Sage"
        case "ink": "Ink"
        default: "Theme"
        }
    }
}

extension WidgetStyle {
    var title: LocalizedStringKey {
        switch self {
        case .note: "The note"
        case .minimal: "Just words"
        case .print: "Print"
        case .bold: "Bold"
        }
    }
}

/// Step-by-step instructions, since adding a widget happens outside the app.
struct WidgetHelpView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Put your notes where you’ll see them")
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)

                    if !app.widgets.isAvailable {
                        NoticeBanner("Widgets aren’t available in this build because its App Group isn’t set up.", tone: .info)
                    }

                    SectionHeading("Home Screen")
                    HelpStep(number: 1, text: "Touch and hold an empty area of your Home Screen until the apps jiggle.")
                    HelpStep(number: 2, text: "Tap Edit, then Add Widget.")
                    HelpStep(number: 3, text: "Search for \(app.configuration.displayName), choose a size, and tap Add Widget.")

                    SectionHeading("Lock Screen")
                    HelpStep(number: 1, text: "Touch and hold your Lock Screen, then tap Customise.")
                    HelpStep(number: 2, text: "Tap the widget area under the clock and choose \(app.configuration.displayName).")

                    VStack(alignment: .leading, spacing: Space.xs) {
                        SectionHeading("Good to know")
                        Text("iOS decides when widgets refresh, to save battery. A new note usually appears within a few minutes, and always when you open the app. Tapping the widget opens the note.")
                            .font(Typo.callout)
                            .foregroundStyle(palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.gutter)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("widgetHelp.done")
                }
            }
        }
    }
}

struct HelpStep: View {
    @Environment(\.palette) private var palette
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text("\(number)")
                .font(.system(.callout, design: .serif).weight(.semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 22, alignment: .leading)
            Text(text)
                .font(Typo.body)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
