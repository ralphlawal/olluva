import CoupleDesign
import CoupleDomain
import SwiftUI

/// The three places in the app. Navigation is deliberately small: today's
/// note, what you've kept, and the two of you.
struct MainView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var composerRequest: ComposerRequest?
    @State private var showingPriming = false
    @State private var showingBackupOffer = false
    @State private var toast: LocalizedStringKey?

    var body: some View {
        @Bindable var router = app.router
        TabView(selection: $router.tab) {
            HomeView(compose: { composerRequest = $0 })
                .tabItem { Label("Today", systemImage: "note.text") }
                .tag(AppRouter.Tab.today)
            MemoriesView()
                .tabItem { Label("Memories", systemImage: "book.closed") }
                .tag(AppRouter.Tab.memories)
            UsView(compose: { composerRequest = $0 })
                .tabItem { Label("Us", systemImage: "person.2") }
                .tag(AppRouter.Tab.us)
        }
        .toast($toast)
        .fullScreenCover(item: $composerRequest) { request in
            ComposerView(request: request) { outcome in
                switch outcome {
                case .sent: toast = "Sent"
                case .scheduled: toast = "Scheduled"
                case .saved: toast = "Saved"
                case .queued: toast = "We’ll send it when you’re back online"
                }
            }
        }
        .sheet(item: Binding(
            get: { router.presentedNoteID.flatMap { app.notes.note(id: $0) } },
            set: { if $0 == nil { router.presentedNoteID = nil } }
        )) { note in
            NoteDetailView(note: note, compose: { request in
                router.presentedNoteID = nil
                // Let the sheet finish closing before the composer covers the screen.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    composerRequest = request
                }
            })
        }
        .sheet(isPresented: $router.isShowingPaywall) { PaywallView() }
        .sheet(isPresented: $showingPriming) { NotificationPrimingSheet() }
        .sheet(isPresented: $showingBackupOffer) { BackupOfferSheet() }
        .onChange(of: router.isComposing, initial: true) { _, composing in
            guard composing else { return }
            router.isComposing = false
            composerRequest = ComposerRequest(mode: .new)
        }
        .task {
            // Ask about notifications once, after pairing, when there is a
            // partner whose notes they would actually be about.
            await app.notifications.refreshAuthorization()
            if !app.settings.notificationPrimingShown, app.notifications.authorization == .notDetermined,
               !app.configuration.isUITesting {
                try? await Task.sleep(for: .seconds(1.2))
                showingPriming = true
            } else if !app.session.isBackedUp, !app.settings.backupOfferShown,
                      !app.configuration.isUITesting || app.configuration.showsBackupOffer {
                // One prompt at a time: this waits for a launch on which the
                // notification question is not also being asked.
                try? await Task.sleep(for: .seconds(1.2))
                showingBackupOffer = true
            }
        }
    }
}

// Screen: Home ("Today")
// Purpose: show the newest note from your partner, and make answering it one tap.
// Primary action: write a note.
// Layouts weighed: a split screen of "theirs / yours" (gives equal weight to
// the less interesting half), a swipeable deck of every note (turns a glance
// into a browsing task), and a single note on the page with everything else
// subordinate. The single note is used: it is the only element with depth,
// the largest thing on screen, and everything beneath it is plain text rows.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    let compose: (ComposerRequest) -> Void
    @State private var showingPersonalise = false

    private var partner: Profile? { app.session.partner }
    private var received: Note? { app.notes.latestReceived(by: app.session.userID) }
    private var sent: Note? { app.notes.latestSent(by: app.session.userID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    if app.backend.isDemo, !ProcessInfo.processInfo.arguments.contains("-storeScreenshots") { demoBanner }
                    hero
                    composeActions
                    TogetherCard()
                    if !app.notes.pending.isEmpty { pendingSection }
                    if let sent { sentSection(sent) }
                    datesSection
                    NavigationLink {
                        NotesHistoryView()
                    } label: {
                        HomeLinkRow(symbol: "clock.arrow.circlepath", title: "Earlier notes")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.history")
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pageBackground(palette)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await app.refreshContent() }
            .sheet(isPresented: $showingPersonalise) { PersonaliseView() }
            .navigationDestination(isPresented: Bindable(app.router).isShowingTogether) { TogetherView() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            // The two of you, your partner in front.
            HStack(spacing: -14) {
                ProfileAvatar(profile: partner, size: 48)
                    .overlay(Circle().strokeBorder(palette.canvas, lineWidth: 2))
                    .zIndex(1)
                ProfileAvatar(profile: app.session.profile, size: 48)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(partner?.displayName ?? "")
                    .font(Typo.heading)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(connectionLine)
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.xs)
            Button {
                showingPersonalise = true
            } label: {
                Image(systemName: "paintbrush")
            }
            .buttonStyle(.circleIcon(diameter: Size.touch))
            .accessibilityLabel(Text("Personalise"))
            .accessibilityIdentifier("home.personalise")
        }
    }

    private var connectionLine: String {
        guard let since = app.session.space.space?.pairedAt else { return String(localized: "Connected") }
        let days = max(0, Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 0)
        return days == 0 ? String(localized: "Connected today") : String(localized: "Together \(days) days")
    }

    private var demoBanner: some View {
        NoticeBanner("Demo mode. Nothing here is saved or sent anywhere.", tone: .info)
    }

    // MARK: The note

    @ViewBuilder
    private var hero: some View {
        switch app.notes.loadState {
        case .idle, .loading:
            SkeletonBlock(cornerRadius: Radius.paper)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, Space.xs)
        case .failed(let error):
            LoadFailureView(error.message) {
                Task { await app.refreshContent() }
            }
            .padding(.vertical, Space.xl)
            .frame(maxWidth: .infinity)
        case .loaded:
            if let received {
                receivedNote(received)
            } else {
                firstNotePrompt
            }
        }
    }

    private func receivedNote(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                if note.seenAt == nil {
                    Circle().fill(palette.highlight).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("New").overlineStyle(palette).foregroundStyle(palette.highlight)
                    Text("·").foregroundStyle(palette.inkTertiary).accessibilityHidden(true)
                }
                Text(note.createdAt, format: .relative(presentation: .named))
                    .overlineStyle(palette)
                if note.origin == .scheduled {
                    Label("A surprise", systemImage: "gift")
                        .labelStyle(.titleAndIcon)
                        .overlineStyle(palette)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                app.router.presentedNoteID = note.id
            } label: {
                PaperNote(tilt: -1.2) {
                    LoadedNoteCard(content: note.content)
                }
                .padding(.horizontal, Space.xs)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the note"))
            .accessibilityIdentifier("home.latestNote")
        }
    }

    /// The very first screen a new couple sees: an invitation to begin, in the
    /// shape of the thing they are about to make.
    private var firstNotePrompt: some View {
        Button {
            compose(ComposerRequest(mode: .new))
        } label: {
            VStack(spacing: Space.sm) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(palette.inkTertiary)
                Text("A blank page")
                    .font(Typo.heading)
                    .foregroundStyle(palette.ink)
                Text("Nothing from \(partner?.displayName ?? "") yet. Leave them something to find.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.paper, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.paper, style: .continuous)
                    .strokeBorder(palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
            )
            .padding(.horizontal, Space.xs)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.firstNote")
    }

    // MARK: Compose

    private var composeActions: some View {
        HStack(spacing: Space.sm) {
            Button {
                Haptics.tap()
                compose(ComposerRequest(mode: received.map { .reply(to: $0) } ?? .new))
            } label: {
                Label(received == nil ? "Write a note" : "Write back", systemImage: "square.and.pencil")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("home.compose")

            Button {
                compose(ComposerRequest(mode: .new, startingTool: .draw))
            } label: {
                Image(systemName: "scribble.variable")
            }
            .buttonStyle(.circleIcon)
            .accessibilityLabel(Text("Draw a note"))
            .accessibilityIdentifier("home.draw")

            Button {
                compose(ComposerRequest(mode: .new, startingTool: .photo))
            } label: {
                Image(systemName: "photo")
            }
            .buttonStyle(.circleIcon)
            .accessibilityLabel(Text("Send a photo"))
            .accessibilityIdentifier("home.photo")
        }
    }

    // MARK: Waiting to send

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeading("Waiting to send")
            ForEach(app.notes.pending) { item in
                HStack(spacing: Space.sm) {
                    NoteCardView(content: item.content)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.state == .failed ? "Not sent yet" : "Sending…")
                            .font(Typo.calloutStrong)
                            .foregroundStyle(item.state == .failed ? palette.danger : palette.ink)
                        Text(item.state == .failed ? "We’ll keep trying while the app is open." : "Hold on a moment.")
                            .font(Typo.caption)
                            .foregroundStyle(palette.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    if item.state == .failed {
                        Menu {
                            Button("Try now") { Task { try? await app.notes.retry(item.id) } }
                            Button("Discard", role: .destructive) { app.notes.discard(item.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: Size.touch, height: Size.touch)
                                .foregroundStyle(palette.ink)
                        }
                        .accessibilityLabel(Text("Options for unsent note"))
                    } else {
                        ProgressView()
                    }
                }
                .accessibilityIdentifier("home.pending")
            }
        }
    }

    // MARK: Your last note

    private func sentSection(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeading("Your last note")
            Button {
                app.router.presentedNoteID = note.id
            } label: {
                HStack(spacing: Space.sm) {
                    LoadedNoteCard(content: note.content, maxPixel: 300)
                        .frame(width: 60, height: 60)
                        .paperShadow(palette, lifted: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.createdAt, format: .relative(presentation: .named))
                            .font(Typo.calloutStrong)
                            .foregroundStyle(palette.ink)
                        Text(note.seenAt == nil ? "Delivered" : "Seen")
                            .font(Typo.caption)
                            .foregroundStyle(palette.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    if let reaction = app.notes.reaction(on: note.id, by: partner?.id) {
                        Image(systemName: reaction.symbol)
                            .font(.system(size: Size.iconControl))
                            .foregroundStyle(palette.highlight)
                            .accessibilityLabel(Text("\(partner?.displayName ?? "") reacted: \(reaction.label)"))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.inkTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.sentNote")
        }
    }

    // MARK: Dates

    @ViewBuilder
    private var datesSection: some View {
        let upcoming = app.dates.upcoming(limit: 2)
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeading("Coming up") {
                Button("All dates") { app.router.tab = .us }
                    .font(Typo.calloutStrong)
                    .foregroundStyle(palette.accent)
            }
            if upcoming.isEmpty {
                Button {
                    app.router.tab = .us
                } label: {
                    HomeLinkRow(symbol: "calendar.badge.plus", title: "Add a date you both care about")
                }
                .buttonStyle(.plain)
            } else {
                ForEach(upcoming, id: \.date.id) { item in
                    UpcomingDateRow(item: item)
                }
            }
        }
    }
}

struct HomeLinkRow: View {
    @Environment(\.palette) private var palette
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconControl, weight: .regular))
                .foregroundStyle(palette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title).font(Typo.body).foregroundStyle(palette.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Size.touch)
        .contentShape(Rectangle())
    }
}

struct UpcomingDateRow: View {
    @Environment(\.palette) private var palette
    let item: DateRules.Upcoming

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: item.date.kind.symbol)
                .font(.system(size: Size.iconControl))
                .foregroundStyle(palette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.date.title).font(Typo.body).foregroundStyle(palette.ink)
                Text(item.occursOn.date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
            }
            Spacer(minLength: Space.xs)
            Text(Self.countdown(item.daysAway))
                .font(Typo.calloutStrong)
                .foregroundStyle(item.daysAway == 0 ? palette.highlight : palette.ink)
        }
        .frame(minHeight: Size.touch)
        .accessibilityElement(children: .combine)
    }

    static func countdown(_ days: Int) -> String {
        switch days {
        case 0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        default: String(localized: "In \(days) days")
        }
    }
}

extension ImportantDate.Kind {
    var symbol: String {
        switch self {
        case .anniversary: "heart"
        case .birthday: "birthday.cake"
        case .firstMeeting: "sparkles"
        case .milestone: "flag"
        case .custom: "calendar"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .anniversary: "Anniversary"
        case .birthday: "Birthday"
        case .firstMeeting: "First met"
        case .milestone: "Milestone"
        case .custom: "Something else"
        }
    }
}

extension ReactionKind {
    var symbol: String {
        switch self {
        case .love: "heart.fill"
        case .smile: "face.smiling"
        case .laugh: "hands.clap.fill"
        case .hug: "figure.2.arms.open"
        case .moved: "drop.fill"
        case .spark: "sparkles"
        }
    }

    var label: String {
        switch self {
        case .love: String(localized: "Love")
        case .smile: String(localized: "Smile")
        case .laugh: String(localized: "Applause")
        case .hug: String(localized: "Hug")
        case .moved: String(localized: "Moved")
        case .spark: String(localized: "Sparkle")
        }
    }
}

/// Explains what notifications are for before the system asks permission.
struct NotificationPrimingSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var isAsking = false

    var body: some View {
        VStack(spacing: Space.lg) {
            Spacer(minLength: Space.md)
            Image(systemName: "bell.badge")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            VStack(spacing: Space.xs) {
                Text("Know when \(app.session.partner?.displayName ?? "your partner") writes")
                    .font(Typo.title)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.center)
                Text("We’ll let you know about new notes, surprises and the dates you’ve saved. Nothing else. Notifications don’t show what a note says unless you turn that on.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.md)
            VStack(spacing: Space.xs) {
                Button("Turn on notifications") {
                    isAsking = true
                    Task {
                        await app.notifications.requestAuthorization()
                        finish()
                    }
                }
                .buttonStyle(.primary(isLoading: isAsking))
                .accessibilityIdentifier("priming.allow")
                Button("Not now") { finish() }
                    .buttonStyle(.quiet)
                    .accessibilityIdentifier("priming.skip")
            }
        }
        .padding(Space.gutter)
        .pageBackground(palette)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isAsking)
        .onDisappear { app.settings.notificationPrimingShown = true }
    }

    private func finish() {
        app.settings.notificationPrimingShown = true
        dismiss()
    }
}

/// Offered once, after pairing, when there is finally something to lose.
/// Skippable, and always available afterwards in Settings.
struct BackupOfferSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var action = ActionState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Keep your space safe")
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("You’re connected with \(app.session.partner?.displayName ?? "your partner"). Since there’s no account, your space lives only on this phone for now.")
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BackupExplanation()
                if let error = action.error { NoticeBanner(error.message) }
                VStack(spacing: Space.xs) {
                    BackupButtons(action: action, onDone: { dismiss() })
                    Button("Not now") { dismiss() }
                        .buttonStyle(.quiet)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("backupOffer.skip")
                }
            }
            .padding(Space.gutter)
        }
        .pageBackground(palette)
        .presentationDetents([.large])
        .onDisappear { app.settings.backupOfferShown = true }
    }
}
