import CoupleDesign
import CoupleDomain
import PhotosUI
import StoreKit
import SwiftUI

/// The public site, www.olluva.app, served by Vercel from `site/`.
enum AppLinks {
    static let site = URL(string: "https://www.olluva.app/")!
    static let privacy = site.appendingPathComponent("privacy/")
    static let terms = site.appendingPathComponent("terms/")
    static let support = site.appendingPathComponent("support/")
    static let supportEmail = "hello@olluva.app"
}

// Screen: Settings
// Purpose: everything about the account and the app that is not the
// relationship itself. Primary action: none; it is a directory.
// A plain grouped list is the right tool and the platform convention, so that
// is what this is — restyled only as far as the palette and type scale.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var action = ActionState()
    @State private var confirmingSignOut = false
    @State private var showingPrivacy = false
    @State private var showingWidgetHelp = false
    @State private var exportFile: ExportFile?
    @State private var toast: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            List {
                if let error = action.error {
                    Section { NoticeBanner(error.message).listRowInsets(EdgeInsets()) }
                }

                Section {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        HStack(spacing: Space.md) {
                            ProfileAvatar(profile: app.session.profile, size: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.session.profile?.displayName ?? "").font(Typo.bodyStrong)
                                Text(app.session.isBackedUp ? "Backed up with your Apple ID" : "Only on this phone")
                                    .font(Typo.caption).foregroundStyle(palette.inkSecondary)
                            }
                        }
                        .padding(.vertical, Space.xxs)
                    }
                    .accessibilityIdentifier("settings.profile")
                }

                Section("Premium") {
                    Button {
                        app.router.isShowingPaywall = true
                        if isSheet { dismiss() }
                    } label: {
                        row("sparkles", app.entitlement.isPremium ? "Your Premium" : "See Premium", detail: premiumDetail)
                    }
                    .accessibilityIdentifier("settings.premium")
                    Button {
                        action.run({
                            let found = try await app.purchases.restore()
                            toast = found ? "Purchases restored" : "No purchases to restore"
                        })
                    } label: {
                        row("arrow.clockwise", "Restore purchases")
                    }
                    .disabled(app.purchases.isRestoring)
                    .accessibilityIdentifier("settings.restore")
                }

                Section("App") {
                    NavigationLink { NotificationSettingsView() } label: { row("bell", "Notifications") }
                        .accessibilityIdentifier("settings.notifications")
                    if app.session.phase == .paired {
                        NavigationLink { PersonaliseView().navigationBarBackButtonHidden() } label: { row("paintbrush", "Appearance and widgets") }
                    }
                    Button { showingWidgetHelp = true } label: { row("square.grid.2x2", "How to add the widget") }
                        .accessibilityIdentifier("settings.widgetHelp")
                }

                Section("Privacy and safety") {
                    Button { showingPrivacy = true } label: { row("lock", "How your notes are kept private") }
                    Link(destination: AppLinks.privacy) { row("hand.raised", "Privacy Policy") }
                    Button {
                        action.run({
                            let data = try await app.backend.auth.exportData()
                            exportFile = try ExportFile(data: data)
                        })
                    } label: {
                        row("square.and.arrow.up.on.square", "Export my data", detail: "Everything you’ve written, as a file")
                    }
                    .accessibilityIdentifier("settings.export")
                    if app.session.phase == .paired {
                        NavigationLink { UnlinkView() } label: { row("person.2.slash", "Unlink from \(app.session.partner?.displayName ?? "partner")") }
                            .accessibilityIdentifier("settings.unlink")
                    }
                }

                Section {
                    NavigationLink { BackupView() } label: {
                        row(
                            app.session.isBackedUp ? "checkmark.icloud" : "icloud.and.arrow.up",
                            app.session.isBackedUp ? "Backed up" : "Back up your space",
                            detail: app.session.isBackedUp
                                ? "You can restore it on a new phone with your Apple ID"
                                : "Without a backup, losing this phone means losing your space"
                        )
                    }
                    .accessibilityIdentifier("settings.backup")
                    // Signing out is only offered once there is a way back in.
                    if app.session.isBackedUp {
                        Button { confirmingSignOut = true } label: { row("rectangle.portrait.and.arrow.right", "Sign out of this phone") }
                            .accessibilityIdentifier("settings.signOut")
                    }
                    NavigationLink { DeleteAccountView() } label: {
                        row("trash", "Delete everything").foregroundStyle(palette.danger)
                    }
                    .accessibilityIdentifier("settings.delete")
                } header: {
                    Text("Your space on this phone")
                }

                Section {
                    Link(destination: AppLinks.support) { row("questionmark.circle", "Help and support") }
                    Link(destination: URL(string: "mailto:\(AppLinks.supportEmail)")!) { row("envelope", "Contact us", detail: LocalizedStringKey(AppLinks.supportEmail)) }
                    Link(destination: AppLinks.terms) { row("doc.text", "Terms of Use") }
                } header: {
                    Text("Support")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(app.configuration.displayName) \(app.configuration.version) (\(app.configuration.build))")
                        if app.backend.isDemo { Text("Demo backend: nothing is saved.") }
                    }
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .padding(.top, Space.xs)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .foregroundStyle(palette.ink)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toast($toast)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
                    }
                }
            }
            // Signing out, deleting the account or unlinking changes what is
            // underneath this sheet; it must not linger on top of it.
            .onChange(of: app.session.phase) { _, _ in
                if isSheet { dismiss() }
            }
            .sheet(isPresented: $showingPrivacy) { PrivacyExplainerSheet() }
            .sheet(isPresented: $showingWidgetHelp) { WidgetHelpView() }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url])
            }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out") {
                    action.run { try await app.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your notes stay safe in your shared space. To come back, choose “I already have a space” and sign in with your Apple ID.")
            }
        }
    }

    private var premiumDetail: LocalizedStringKey? {
        switch app.entitlement.source {
        case .own: "Covers you and your partner"
        case .partner: "Included with \(app.session.partner?.displayName ?? "your partner")’s subscription"
        case nil: "One subscription covers you both"
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconInline, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.body).foregroundStyle(palette.ink)
                if let detail {
                    Text(detail).font(Typo.caption).foregroundStyle(palette.inkSecondary)
                }
            }
        }
        .frame(minHeight: 32)
    }
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL

    init(data: Data) throws {
        let name = "my-data-\(Date().formatted(.iso8601.year().month().day())).json"
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Profile

struct ProfileEditView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var name = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var action = ActionState()
    @State private var toast: LocalizedStringKey?

    var body: some View {
        FormPage(title: "Your profile", subtitle: "This is how you appear to your partner.") {
            HStack(spacing: Space.lg) {
                ProfileAvatar(profile: app.session.profile, size: 88)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text(app.session.profile?.avatarPath == nil ? "Add a photo" : "Change photo")
                    }
                    .buttonStyle(.quiet)
                    .accessibilityIdentifier("profile.photo")
                    if app.session.profile?.avatarPath != nil {
                        Button("Remove photo") {
                            action.run {
                                let profile = try await app.backend.profiles.removeAvatar()
                                app.session.setProfile(profile)
                            }
                        }
                        .buttonStyle(.quietDestructive)
                    }
                }
            }

            LabeledField("Name") {
                TextField("Your name", text: $name)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("profile.name")
            }

            if let error = action.error { NoticeBanner(error.message) }

            Button("Save", action: save)
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(!InputRules.isValidDisplayName(name) || name == app.session.profile?.displayName || action.isRunning)
                .accessibilityIdentifier("profile.save")
        }
        .toast($toast)
        .onAppear { name = app.session.profile?.displayName ?? "" }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            action.run {
                defer { pickerItem = nil }
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = ImagePipeline.avatarJPEG(from: data)
                else { throw AppError.mediaUnreadable }
                let profile = try await app.backend.profiles.setAvatar(jpeg: jpeg)
                // The new picture has a new version, so every view showing the
                // old one reloads; keep the copy just uploaded for them.
                if let path = profile.avatarPath {
                    app.media.prime(jpeg, for: path, version: profile.avatarVersion)
                }
                app.session.setProfile(profile)
            }
        }
    }

    private func save() {
        guard InputRules.isValidDisplayName(name) else { return }
        action.run({
            let profile = try await app.backend.profiles.updateProfile(displayName: name, timeZone: nil)
            app.session.setProfile(profile)
        }, onSuccess: { toast = "Saved" })
    }
}

/// Attaches an Apple ID to the space, so it can be restored on another phone.
struct BackupView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var action = ActionState()

    var body: some View {
        FormPage(
            title: app.session.isBackedUp ? "Your space is backed up" : "Back up your space",
            subtitle: app.session.isBackedUp
                ? "If you change or lose this phone, install the app, choose “I already have a space” and sign in with your Apple ID."
                : "There’s no account, so right now your space exists only on this phone."
        ) {
            if app.session.isBackedUp {
                NoticeBanner("Backed up with your Apple ID.", tone: .success)
                    .accessibilityIdentifier("backup.done")
            } else {
                BackupExplanation()
                if let error = action.error { NoticeBanner(error.message) }
                BackupButtons(action: action)
            }
        }
    }
}

struct BackupExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ConsequenceRow(symbol: "iphone.slash", text: "If this phone is lost, reset or replaced, your space can’t be recovered without a backup.")
            ConsequenceRow(symbol: "apple.logo", text: "Backing up links your space to your Apple ID. That’s all: we don’t ask Apple for your name or email.")
            ConsequenceRow(symbol: "arrow.triangle.2.circlepath", text: "On a new phone, sign in with the same Apple ID and everything comes back.")
        }
    }
}

struct BackupButtons: View {
    @Environment(AppEnvironment.self) private var app
    let action: ActionState
    var onDone: (() -> Void)?

    var body: some View {
        AppleIDButton(label: .continue, action: action) { token, nonce in
            try await app.backend.auth.backUpWithApple(idToken: token, nonce: nonce)
            Haptics.success()
            onDone?()
        }
        .disabled(action.isRunning)

        #if DEBUG
        if app.demo != nil {
            Button("Demo: back up with a pretend Apple ID") {
                action.run({
                    try await app.backend.auth.backUpWithApple(idToken: DemoController.appleID, nonce: "demo")
                }, onSuccess: { onDone?() })
            }
            .buttonStyle(.quiet)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("backup.demo")
        }
        #endif
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var action = ActionState()

    var body: some View {
        List {
            Section {
                switch app.notifications.authorization {
                case .denied:
                    VStack(alignment: .leading, spacing: Space.sm) {
                        NoticeBanner("Notifications are turned off for this app in iOS Settings.", tone: .info)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                case .notDetermined:
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Get a quiet heads-up when your partner writes. You choose which kinds below.")
                            .font(Typo.callout)
                            .foregroundStyle(palette.inkSecondary)
                        Button("Turn on notifications") {
                            Task { await app.notifications.requestAuthorization() }
                        }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("notifications.enable")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                default:
                    EmptyView()
                }
            }

            if let error = action.error {
                Section { NoticeBanner(error.message).listRowInsets(EdgeInsets()) }
            }

            switch app.notifications.preferencesState {
            case .idle, .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let error):
                Section {
                    NoticeBanner(error.message, actionTitle: "Try again") {
                        Task { await app.notifications.loadPreferences() }
                    }
                    .listRowInsets(EdgeInsets())
                }
            case .loaded:
                if let preferences = app.notifications.preferences {
                    Section("Tell me about") {
                        toggle("New notes", preferences.newNotes, id: "newNotes") { $0.newNotes = $1 }
                        toggle("Surprises arriving", preferences.surprises, id: "surprises") { $0.surprises = $1 }
                        toggle("Important dates", preferences.importantDates, id: "dates") { $0.importantDates = $1 }
                        toggle("Together: answers and openings", preferences.together, id: "together") { $0.together = $1 }
                        toggle("Together: a new question each morning", preferences.togetherDaily, id: "togetherDaily") { $0.togetherDaily = $1 }
                        toggle("Pairing", preferences.pairing, id: "pairing") { $0.pairing = $1 }
                        toggle("My account", preferences.account, id: "account") { $0.account = $1 }
                    }
                    Section {
                        toggle("Show what a note says", preferences.showPreviews, id: "previews") { $0.showPreviews = $1 }
                    } header: {
                        Text("Privacy")
                    } footer: {
                        Text("When this is off, a notification says who wrote to you but not what they wrote, so nothing personal shows on your Lock Screen.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.canvas.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await app.notifications.refreshAuthorization()
            await app.notifications.loadPreferences()
        }
    }

    private func toggle(
        _ title: LocalizedStringKey, _ value: Bool, id: String,
        _ change: @escaping (inout NotificationPreferences, Bool) -> Void
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { newValue in action.run { try await app.notifications.update { change(&$0, newValue) } } }
        ))
        .font(Typo.body)
        .tint(palette.accent)
        .accessibilityIdentifier("notifications.\(id)")
    }
}

// MARK: - Unlink and delete

/// Unlinking ends the shared space. It is not account deletion, and this
/// screen says exactly what each of the two does.
struct UnlinkView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var blockPartner = false
    @State private var confirming = false
    @State private var action = ActionState()

    var body: some View {
        let name = app.session.partner?.displayName ?? String(localized: "your partner")
        FormPage(title: "Unlink from \(name)", subtitle: "This closes the space you share. It’s different from deleting everything.") {
            VStack(alignment: .leading, spacing: Space.md) {
                ConsequenceRow(symbol: "xmark.circle", text: "The space closes for both of you straight away. Neither of you can open its notes or memories again.")
                ConsequenceRow(symbol: "gift", text: "Surprises that haven’t arrived yet won’t be delivered.")
                ConsequenceRow(symbol: "clock", text: "What you wrote can still be exported for 30 days. After that the space is permanently erased.")
                ConsequenceRow(symbol: "person", text: "You stay set up on this phone, and can pair again with \(name) or someone else.")
            }

            Toggle(isOn: $blockPartner) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also block \(name)").font(Typo.body).foregroundStyle(palette.ink)
                    Text("Their invitations will no longer work for you, and yours won’t work for them.")
                        .font(Typo.caption).foregroundStyle(palette.inkSecondary)
                }
            }
            .tint(palette.accent)
            .accessibilityIdentifier("unlink.block")

            if let error = action.error { NoticeBanner(error.message) }

            Button("Unlink") { confirming = true }
                .buttonStyle(.primary(isLoading: action.isRunning))
                .disabled(action.isRunning)
                .accessibilityIdentifier("unlink.submit")
        }
        .confirmationDialog("Unlink from \(name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                action.run { try await app.session.leaveSpace(blockPartner: blockPartner) }
            }
            .accessibilityIdentifier("unlink.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }
}

struct ConsequenceRow: View {
    @Environment(\.palette) private var palette
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(palette.inkSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.callout)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DeleteAccountView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var confirmation = ""
    @State private var action = ActionState()

    private let word = "DELETE"

    var body: some View {
        FormPage(title: "Delete everything", subtitle: "This permanently removes you and what you’ve made, from this phone and from our servers. It can’t be undone.") {
            VStack(alignment: .leading, spacing: Space.md) {
                ConsequenceRow(symbol: "person.crop.circle.badge.xmark", text: "Your profile, and any backup, are erased.")
                ConsequenceRow(symbol: "note.text", text: "Every note, drawing, photo and memory you created is deleted, including from your partner’s phone.")
                if app.session.phase == .paired {
                    ConsequenceRow(symbol: "person.2.slash", text: "Your shared space closes. Your partner keeps their own account and what they wrote.")
                }
                if app.entitlement.source == .own {
                    ConsequenceRow(symbol: "creditcard", text: "Deleting your account doesn’t cancel a subscription. Cancel it in your Apple ID settings so you aren’t charged again.")
                }
            }

            LabeledField("Type \(word) to confirm") {
                TextField(word, text: $confirmation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("delete.confirmField")
            }

            if let error = action.error { NoticeBanner(error.message) }

            Button("Delete everything") {
                action.run { try await app.deleteAccount() }
            }
            .buttonStyle(.primary(isLoading: action.isRunning))
            .tint(palette.danger)
            .disabled(confirmation.uppercased() != word || action.isRunning)
            .accessibilityIdentifier("delete.submit")
        }
    }
}
