import CoupleDesign
import CoupleDomain
import SwiftUI

// Screen: Together
// Purpose: one question a day that you each answer on your own and then open
// together.
// Primary action: whatever moves the moment on. Answer it; then, when both
// have, open it.
// Layouts weighed: a chat-like thread of question and replies (makes private
// answers look like messages and invites reading ahead), a full-screen card
// that swaps between steps (hides where you are in the day), and a single
// page with the question at the top and one state beneath it. The single page
// is used: the question never moves, and what is under it is always the one
// thing to do next.
struct TogetherView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let moment = app.together.today {
                    if app.together.isStale {
                        NoticeBanner("You’re offline. This may be out of date.", tone: .info, actionTitle: "Try again") {
                            Task { await app.together.load() }
                        }
                    }
                    TogetherMomentView(moment: moment, isToday: true)
                    NavigationLink {
                        TogetherHistoryView()
                    } label: {
                        HomeLinkRow(symbol: "clock.arrow.circlepath", title: "Earlier questions")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("together.history")
                } else if app.together.isUnpaired {
                    EmptyStateView(
                        symbol: "person.2", title: "This is for the two of you",
                        message: "Once you’re connected with your partner, you’ll each get the same question every day."
                    ) {
                        Button("Back to Today") { dismiss() }.buttonStyle(.secondary).frame(maxWidth: 220)
                    }
                    .padding(.top, Space.xxl)
                } else if let error = app.together.loadState.error {
                    LoadFailureView(error.message) { Task { await app.together.load() } }
                        .padding(.top, Space.xxl)
                } else {
                    TogetherSkeleton()
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .pageBackground(palette)
        .navigationTitle("Together")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.together.load() }
        .task { await app.together.load() }
        .accessibilityIdentifier("together.screen")
    }
}

/// The placeholder while today's question is fetched.
private struct TogetherSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SkeletonBlock(cornerRadius: Radius.card).frame(height: 150)
            SkeletonBlock(cornerRadius: Radius.field).frame(height: 140)
            SkeletonBlock(cornerRadius: Radius.field).frame(height: 52)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading today’s question"))
    }
}

// MARK: - One moment, in whatever state it is in

/// A question and what has happened to it so far. Used for today's and for
/// any earlier one, so both behave identically.
struct TogetherMomentView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let moment: TogetherMoment
    var isToday = false

    @State private var text = ""
    @State private var isEditing = false
    @State private var isOpened = false
    @FocusState private var isWriting: Bool

    private var partnerName: String { app.session.partner?.displayName ?? String(localized: "Your partner") }
    private var isComposing: Bool { moment.status == .open || (isEditing && moment.status != .revealed) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            questionCard
            if let error = app.together.actionError { NoticeBanner(error.message) }
            if isComposing {
                composer
            } else {
                switch moment.status {
                case .open: EmptyView()
                case .waiting: waiting
                case .ready: ready
                case .revealed: revealed
                }
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.gentle, value: moment.status)
        .animation(Motion.fade, value: isEditing)
        .onAppear {
            text = app.together.draft(for: moment.id)
            isOpened = moment.status == .revealed && app.together.hasPlayedReveal(moment.id)
        }
        .onChange(of: moment.status) { _, status in
            if status == .revealed { isEditing = false }
        }
        .onDisappear { app.together.actionError = nil }
    }

    // MARK: Question

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(isToday ? String(localized: "Today’s question") : moment.day.date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .overlineStyle(palette)
            Text(moment.question.body)
                .font(Typo.title)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("together.question")
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sunken, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Answering

    private var composer: some View {
        let count = TogetherRules.cleaned(text).count
        let isOver = count > TogetherRules.answerLimit
        return VStack(alignment: .leading, spacing: Space.sm) {
            if moment.status == .open, moment.partnerAnswered {
                Label("\(partnerName) has answered. Your turn.", systemImage: "checkmark.circle")
                    .font(Typo.calloutStrong)
                    .foregroundStyle(palette.highlight)
                    .accessibilityIdentifier("together.partnerAnswered")
            }

            TextEditor(text: $text)
                .font(Typo.body)
                .foregroundStyle(palette.ink)
                .scrollContentBackground(.hidden)
                .focused($isWriting)
                .frame(minHeight: 140)
                .padding(Space.sm)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write your answer…")
                            .font(Typo.body)
                            .foregroundStyle(palette.inkTertiary)
                            .padding(.horizontal, Space.sm + 5)
                            .padding(.vertical, Space.sm + 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(Text("Your answer"))
                .accessibilityIdentifier("together.answer")
                .onChange(of: text) { _, value in
                    // Kept as a draft on this phone as it is typed. A draft is
                    // not an answer: nothing is sent until the button is used.
                    if !isEditing || value != moment.myAnswer { app.together.setDraft(value, for: moment.id) }
                }

            HStack(alignment: .firstTextBaseline) {
                Text(text.isEmpty ? "" : isEditing ? "Not saved yet" : "Draft, saved on this phone")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .accessibilityIdentifier("together.draftNote")
                Spacer()
                Text("\(count)/\(TogetherRules.answerLimit)")
                    .font(Typo.caption)
                    .monospacedDigit()
                    .foregroundStyle(isOver ? palette.highlight : palette.inkSecondary)
                    .accessibilityLabel(Text("\(count) of \(TogetherRules.answerLimit) characters"))
            }

            Button {
                isWriting = false
                Task {
                    if await app.together.submit(momentID: moment.id, answer: text) {
                        Haptics.success()
                        isEditing = false
                    } else {
                        Haptics.warning()
                    }
                }
            } label: {
                Text(isEditing ? "Save my answer" : "Send my answer")
            }
            .buttonStyle(.primary(isLoading: app.together.isSubmitting))
            .disabled(!TogetherRules.isValid(text) || app.together.isSubmitting)
            .accessibilityIdentifier("together.submit")

            if isEditing {
                Button("Cancel") {
                    isEditing = false
                    text = ""
                    app.together.setDraft("", for: moment.id)
                }
                .buttonStyle(.quiet)
                .frame(maxWidth: .infinity)
            }

            Label("\(partnerName) won’t see this until you’ve both answered and opened it together.", systemImage: "lock")
                .font(Typo.caption)
                .foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Waiting

    private var waiting: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Label("Your answer is in", systemImage: "checkmark.circle.fill")
                    .font(Typo.heading)
                    .foregroundStyle(palette.ink)
                Text("Your shared moment is waiting for both of you.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("together.waiting")

            answerCard(name: String(localized: "You"), text: moment.myAnswer, identifier: "together.answer.mine", canEdit: true)
            sealedCard(title: "\(partnerName) hasn’t answered yet", symbol: "hourglass")
        }
    }

    // MARK: Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("You’ve both answered")
                    .font(Typo.heading)
                    .foregroundStyle(palette.ink)
                Text("Open it when you’re ready. You’ll both see each other’s answer.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("together.ready")

            answerCard(name: String(localized: "You"), text: moment.myAnswer, identifier: "together.answer.mine", canEdit: true)
            sealedCard(title: "\(partnerName)’s answer is sealed", symbol: "envelope")

            Button {
                Task {
                    if await app.together.reveal(momentID: moment.id) { Haptics.success() } else { Haptics.warning() }
                }
            } label: {
                Label("Open together", systemImage: "sparkles")
            }
            .buttonStyle(.primary(isLoading: app.together.isRevealing))
            .disabled(app.together.isRevealing)
            .accessibilityIdentifier("together.reveal")
        }
    }

    // MARK: Revealed

    private var revealed: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            answerCard(name: partnerName, text: moment.partnerAnswer, identifier: "together.answer.partner", canEdit: false)
                .modifier(Unfold(isOpen: isOpened, reduceMotion: reduceMotion))
            answerCard(name: String(localized: "You"), text: moment.myAnswer, identifier: "together.answer.mine", canEdit: false)
                .modifier(Unfold(isOpen: isOpened, reduceMotion: reduceMotion))

            if let date = moment.revealedAt {
                Text("Opened \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .opacity(isOpened ? 1 : 0)
            }

            Button {
                Task { await app.together.setSaved(moment.memoryID == nil, momentID: moment.id) }
            } label: {
                Label(
                    moment.memoryID == nil ? "Save to Memories" : "Saved to Memories",
                    systemImage: moment.memoryID == nil ? "bookmark" : "bookmark.fill"
                )
            }
            .buttonStyle(.secondary)
            .disabled(app.together.isSavingMemory)
            .opacity(isOpened ? 1 : 0)
            .accessibilityHint(moment.memoryID == nil ? Text("Keeps this in your shared scrapbook") : Text("Removes it from your scrapbook. Your answers stay here."))
            .accessibilityIdentifier("together.save")
        }
        .task(id: moment.id) {
            // Played once on each phone. Afterwards the answers are simply there.
            guard !isOpened else { return }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 350))
            withAnimation(reduceMotion ? Motion.fade : .spring(response: 0.7, dampingFraction: 0.82)) { isOpened = true }
            app.together.markRevealPlayed(moment.id)
            AccessibilityNotification.Announcement(String(localized: "Both answers are open.")).post()
        }
    }

    // MARK: Pieces

    private func answerCard(name: String, text: String?, identifier: String, canEdit: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(name).overlineStyle(palette)
                Spacer()
                if canEdit {
                    Button("Edit") {
                        self.text = moment.myAnswer ?? ""
                        isEditing = true
                        isWriting = true
                    }
                    .font(Typo.calloutStrong)
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("together.edit")
                }
            }
            if let text {
                Text(text)
                    .font(Typo.body)
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(identifier)
            } else {
                Text("This answer is no longer available.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func sealedCard(title: String, symbol: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.inkTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Typo.callout)
                .foregroundStyle(palette.inkSecondary)
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .strokeBorder(palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("together.sealed")
    }
}

/// How an answer arrives when a moment is opened: it lifts and unfolds into
/// place. With Reduce Motion it simply fades in.
private struct Unfold: ViewModifier {
    let isOpen: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isOpen ? 1 : 0)
            .scaleEffect(reduceMotion || isOpen ? 1 : 0.94, anchor: .top)
            .rotation3DEffect(.degrees(reduceMotion || isOpen ? 0 : -24), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
            .offset(y: reduceMotion || isOpen ? 0 : 14)
    }
}

// MARK: - History

// Screen: Earlier questions
// Purpose: find a question you both answered before and read it again.
// Primary action: open one.
// Layouts weighed: a calendar (most days would be empty, which reads as a
// record of what was missed), cards showing both answers in full (long, and
// puts private words on screen while scrolling past), and a plain dated list
// of questions. The list is used. It shows only days you finished together;
// a day that was skipped is simply not there.
struct TogetherHistoryView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.sm) {
                switch app.together.historyState {
                case .idle, .loading:
                    ForEach(0..<4, id: \.self) { _ in SkeletonBlock(cornerRadius: Radius.field).frame(height: 76) }
                case .failed(let error):
                    LoadFailureView(error.message) { Task { await app.together.loadHistory() } }
                        .padding(.top, Space.xxl)
                case .loaded:
                    if app.together.history.isEmpty {
                        EmptyStateView(
                            symbol: "bubble.left.and.bubble.right", title: "Nothing here yet",
                            message: "Questions you’ve both answered are kept here, so you can read them again."
                        )
                        .padding(.top, Space.xxl)
                    } else {
                        ForEach(app.together.history) { moment in
                            NavigationLink {
                                TogetherMomentDetailView(momentID: moment.id)
                            } label: {
                                row(moment)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("together.history.row")
                            .task {
                                if moment.id == app.together.history.last?.id { await app.together.loadMoreHistory() }
                            }
                        }
                        if app.together.isLoadingMoreHistory {
                            ProgressView().frame(maxWidth: .infinity).padding(Space.md)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .pageBackground(palette)
        .navigationTitle("Earlier questions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.together.loadHistory() }
        .task { await app.together.loadHistory() }
    }

    private func row(_ moment: TogetherMoment) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(moment.day.date(), format: .dateTime.day().month(.wide).year())
                        .overlineStyle(palette)
                    if moment.status == .ready {
                        Text("Ready to open")
                            .font(Typo.overline)
                            .foregroundStyle(palette.highlight)
                    }
                }
                Text(moment.question.body)
                    .font(Typo.bodyStrong)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.xs)
            if moment.memoryID != nil {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.highlight)
                    .accessibilityLabel(Text("Saved to Memories"))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One earlier moment, opened from the history or from a saved memory.
struct TogetherMomentDetailView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    let momentID: UUID
    @State private var didLoad = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let moment = app.together.moment(id: momentID) {
                    TogetherMomentView(moment: moment, isToday: moment.id == app.together.today?.id)
                } else if didLoad {
                    EmptyStateView(
                        symbol: "questionmark.bubble", title: "This isn’t available",
                        message: "It may belong to a space that has ended."
                    )
                    .padding(.top, Space.xxl)
                } else {
                    SkeletonBlock(cornerRadius: Radius.card).frame(height: 150)
                    SkeletonBlock(cornerRadius: Radius.field).frame(height: 120)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .pageBackground(palette)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            _ = await app.together.loadMoment(id: momentID)
            didLoad = true
        }
    }
}

// MARK: - The card on Today

/// The way in from Today: the question, and where the two of you are with it.
struct TogetherCard: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette

    private var partnerName: String { app.session.partner?.displayName ?? String(localized: "Your partner") }

    var body: some View {
        Group {
            if let moment = app.together.today {
                Button {
                    app.router.isShowingTogether = true
                } label: {
                    content(moment)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.together")
            } else if app.together.loadState.isLoading || app.together.loadState == .idle {
                SkeletonBlock(cornerRadius: Radius.card).frame(height: 104)
            } else if app.together.loadState.error != nil {
                // Quietly offer another go; Today has more important things on it.
                Button {
                    Task { await app.together.load() }
                } label: {
                    HomeLinkRow(symbol: "arrow.clockwise", title: "Load today’s question")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func content(_ moment: TogetherMoment) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Together").overlineStyle(palette)
                Text(moment.question.body)
                    .font(Typo.heading)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status(moment))
                    .font(Typo.caption)
                    .foregroundStyle(needsMe(moment) ? palette.highlight : palette.inkSecondary)
            }
            Spacer(minLength: Space.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sunken, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func needsMe(_ moment: TogetherMoment) -> Bool {
        moment.status == .ready || (moment.status == .open && moment.partnerAnswered)
    }

    private func status(_ moment: TogetherMoment) -> String {
        switch moment.status {
        case .open:
            moment.partnerAnswered
                ? String(localized: "\(partnerName) has answered. Your turn.")
                : String(localized: "Answer today’s question.")
        case .waiting: String(localized: "Your answer is in. Waiting for \(partnerName).")
        case .ready: String(localized: "You’ve both answered. Open it together.")
        case .revealed: String(localized: "You both answered today.")
        }
    }
}
