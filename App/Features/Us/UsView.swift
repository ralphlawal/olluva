import CoupleDesign
import CoupleDomain
import SwiftUI

// Screen: Us
// Purpose: the things that belong to the relationship rather than to a single
// note — the dates you keep, the surprises you've planned, how your space looks.
// Primary action: none dominates; this is a place you visit to tend things.
// Layouts weighed: a settings-style grouped list (reads as admin), a dashboard
// of tiles with counts (metrics nobody asked for), and a single quiet page of
// headed sections. The page is used, opening with the two of you.
struct UsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    let compose: (ComposerRequest) -> Void

    @State private var editingDate: DateEditorTarget?
    @State private var showingPersonalise = false
    @State private var showingSettings = false
    @State private var cancelTarget: ScheduledMessage?
    @State private var action = ActionState()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    couple
                    if let error = action.error { NoticeBanner(error.message) }
                    datesSection
                    surprisesSection
                    VStack(spacing: 0) {
                        Button { showingPersonalise = true } label: {
                            HomeLinkRow(symbol: "paintbrush", title: "Personalise your space")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("us.personalise")
                        Hairline()
                        Button { showingSettings = true } label: {
                            HomeLinkRow(symbol: "gearshape", title: "Settings")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("us.settings")
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pageBackground(palette)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await app.refreshContent() }
            .sheet(item: $editingDate) { DateEditorView(target: $0) }
            .sheet(isPresented: $showingPersonalise) { PersonaliseView() }
            .sheet(isPresented: $showingSettings) { SettingsView(isSheet: true) }
            .confirmationDialog("Cancel this surprise?", isPresented: Binding(
                get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }
            ), titleVisibility: .visible) {
                Button("Cancel surprise", role: .destructive) {
                    guard let target = cancelTarget else { return }
                    action.run { try await app.schedule.cancel(target) }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("It won’t be delivered.")
            }
        }
    }

    private var couple: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: -14) {
                ProfileAvatar(profile: app.session.profile, size: 64)
                ProfileAvatar(profile: app.session.partner, size: 64)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("\(app.session.profile?.displayName ?? "") & \(app.session.partner?.displayName ?? "")")
                    .font(Typo.display)
                    .foregroundStyle(palette.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let since = app.session.space.space?.pairedAt {
                    Text("Sharing this space since \(since, format: .dateTime.day().month(.wide).year())")
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                }
            }
        }
    }

    // MARK: Dates

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeading("Important dates") {
                Button {
                    addDate()
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(.iconOnly)
                        .frame(width: Size.touch, height: 28, alignment: .trailing)
                }
                .foregroundStyle(palette.accent)
                .accessibilityLabel(Text("Add a date"))
                .accessibilityIdentifier("us.addDate")
            }
            switch app.dates.loadState {
            case .idle, .loading:
                SkeletonBlock().frame(height: Size.touch)
                SkeletonBlock().frame(height: Size.touch)
            case .failed(let error):
                NoticeBanner(error.message, actionTitle: "Try again") {
                    Task { if let id = app.session.coupleID { await app.dates.load(coupleID: id) } }
                }
            case .loaded:
                let upcoming = app.dates.upcoming()
                let past = app.dates.past()
                if upcoming.isEmpty, past.isEmpty {
                    Text("Anniversaries, birthdays, the day you met. We’ll remind you both, or just you if it’s a secret.")
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Add your first date") { addDate() }
                        .buttonStyle(.secondary)
                        .padding(.top, Space.xs)
                        .accessibilityIdentifier("us.addFirstDate")
                } else {
                    ForEach(upcoming, id: \.date.id) { item in
                        Button {
                            editingDate = DateEditorTarget(date: item.date)
                        } label: {
                            UpcomingDateRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("us.dateRow")
                    }
                    ForEach(past) { date in
                        Button {
                            editingDate = DateEditorTarget(date: date)
                        } label: {
                            HStack {
                                Image(systemName: date.kind.symbol).foregroundStyle(palette.inkTertiary).frame(width: 28)
                                Text(date.title).font(Typo.body).foregroundStyle(palette.inkSecondary)
                                Spacer()
                                Text(date.startsOn.date(), format: .dateTime.day().month().year())
                                    .font(Typo.caption).foregroundStyle(palette.inkSecondary)
                            }
                            .frame(minHeight: Size.touch)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func addDate() {
        guard let coupleID = app.session.coupleID, let userID = app.session.userID else { return }
        editingDate = DateEditorTarget(date: nil, coupleID: coupleID, userID: userID)
    }

    // MARK: Surprises

    private var surprisesSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeading("Surprises")
            let pending = app.schedule.pending
            if pending.isEmpty {
                Text("Write a note now and have it arrive later: on the morning of a big day, or just when they least expect it.")
                    .font(Typo.callout)
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pending) { message in
                HStack(spacing: Space.sm) {
                    LoadedNoteCard(content: message.content, maxPixel: 300)
                        .frame(width: 56, height: 56)
                        .paperShadow(palette, lifted: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arrives \(message.deliverAt, format: .dateTime.weekday().day().month().hour().minute())")
                            .font(Typo.calloutStrong)
                            .foregroundStyle(palette.ink)
                        Text("Only you can see this until then")
                            .font(Typo.caption)
                            .foregroundStyle(palette.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button { compose(ComposerRequest(mode: .editScheduled(message))) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) { cancelTarget = message } label: {
                            Label("Cancel surprise", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(palette.ink)
                            .frame(width: Size.touch, height: Size.touch)
                    }
                    .accessibilityLabel(Text("Options for this surprise"))
                    .accessibilityIdentifier("us.surpriseMenu")
                }
                .accessibilityIdentifier("us.surpriseRow")
            }
            ForEach(app.schedule.history.prefix(3)) { message in
                HStack(spacing: Space.sm) {
                    Image(systemName: message.status.symbol)
                        .foregroundStyle(message.status == .failed ? palette.danger : palette.inkTertiary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(message.status.label)
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                    Spacer()
                    Text(message.deliverAt, format: .dateTime.day().month().hour().minute())
                        .font(Typo.caption)
                        .foregroundStyle(palette.inkSecondary)
                }
                .frame(minHeight: 36)
                .accessibilityElement(children: .combine)
            }
            Button {
                if EntitlementRules.canSchedule(pendingCount: pending.count, entitlement: app.entitlement) {
                    compose(ComposerRequest(mode: .surprise))
                } else {
                    app.router.isShowingPaywall = true
                }
            } label: {
                Label("Plan a surprise", systemImage: "gift")
            }
            .buttonStyle(.secondary)
            .padding(.top, Space.xs)
            .accessibilityIdentifier("us.planSurprise")
        }
    }
}

extension ScheduledMessage.Status {
    var symbol: String {
        switch self {
        case .pending: "clock"
        case .delivered: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .pending: "Waiting"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        case .failed: "Couldn’t be delivered"
        }
    }
}

// MARK: - Date editor

struct DateEditorTarget: Identifiable {
    let id = UUID()
    let existing: ImportantDate?
    let coupleID: UUID
    let userID: UUID

    init(date: ImportantDate) {
        existing = date
        coupleID = date.coupleID
        userID = date.createdBy
    }

    init(date: ImportantDate?, coupleID: UUID, userID: UUID) {
        existing = date
        self.coupleID = coupleID
        self.userID = userID
    }
}

struct DateEditorView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let target: DateEditorTarget

    @State private var title = ""
    @State private var kind = ImportantDate.Kind.anniversary
    @State private var day = Date()
    @State private var recurrence = ImportantDate.Recurrence.yearly
    @State private var isPrivate = false
    @State private var notify = true
    @State private var reminders: Set<Int> = [0]
    @State private var action = ActionState()
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    private var isOwner: Bool { target.existing.map { $0.createdBy == app.session.userID } ?? true }

    var body: some View {
        NavigationStack {
            FormPage(title: target.existing == nil ? "A date to remember" : "Edit date", subtitle: nil) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    LabeledField("What is it") {
                        TextField("Our anniversary", text: $title)
                            .focused($titleFocused)
                            .onChange(of: title) { _, value in title = String(value.prefix(Validation.dateTitleLimit)) }
                            .accessibilityIdentifier("date.title")
                    }

                    VStack(spacing: 0) {
                        settingRow("Kind") {
                            Picker("Kind", selection: $kind) {
                                ForEach(ImportantDate.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("date.kind")
                        }
                        Hairline()
                        DatePicker("Date", selection: $day, displayedComponents: .date)
                            .frame(minHeight: Size.button)
                            .accessibilityIdentifier("date.day")
                        Hairline()
                        settingRow("Repeats") {
                            Picker("Repeats", selection: $recurrence) {
                                Text("Every year").tag(ImportantDate.Recurrence.yearly)
                                Text("Every month").tag(ImportantDate.Recurrence.monthly)
                                Text("Just once").tag(ImportantDate.Recurrence.none)
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("date.recurrence")
                        }
                    }
                    .font(Typo.body)
                    .foregroundStyle(palette.ink)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Toggle("Remind us", isOn: $notify)
                            .font(Typo.body)
                            .foregroundStyle(palette.ink)
                            .accessibilityIdentifier("date.notify")
                        if notify {
                            ReminderChips(selection: $reminders)
                            Text("Reminders arrive around 9 in the morning, your time.")
                                .font(Typo.caption)
                                .foregroundStyle(palette.inkSecondary)
                        }
                    }

                    if isOwner {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Toggle("Only I can see this", isOn: $isPrivate)
                                .font(Typo.body)
                                .foregroundStyle(palette.ink)
                                .accessibilityIdentifier("date.private")
                            Text("Useful when you’re planning something. Your partner won’t see the date or get reminders.")
                                .font(Typo.caption)
                                .foregroundStyle(palette.inkSecondary)
                        }
                    }
                }
                .disabled(action.isRunning)

                if let error = action.error { NoticeBanner(error.message) }

                VStack(spacing: Space.xs) {
                    Button(target.existing == nil ? "Save date" : "Save changes", action: save)
                        .buttonStyle(.primary(isLoading: action.isRunning))
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || action.isRunning)
                        .accessibilityIdentifier("date.save")
                    if target.existing != nil {
                        Button("Delete date") { confirmingDelete = true }
                            .buttonStyle(.quietDestructive)
                            .accessibilityIdentifier("date.delete")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog("Delete this date?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let existing = target.existing else { return }
                    action.run({ try await app.dates.delete(existing) }, onSuccess: { dismiss() })
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear(perform: load)
    }

    private func settingRow<Control: View>(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
        .frame(minHeight: Size.button)
    }

    private func load() {
        if let existing = target.existing {
            title = existing.title
            kind = existing.kind
            day = existing.startsOn.date()
            recurrence = existing.recurrence
            isPrivate = existing.visibility == .private
            notify = existing.notify
            reminders = Set(existing.remindDaysBefore)
        } else {
            reminders = [0, 7]
            titleFocused = true
        }
    }

    private func save() {
        let date = ImportantDate(
            id: target.existing?.id ?? UUID(), coupleID: target.coupleID, createdBy: target.userID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, startsOn: DayDate(day),
            recurrence: recurrence, visibility: isPrivate ? .private : .shared, notify: notify,
            remindDaysBefore: DateRules.sanitizedReminders(Array(reminders))
        )
        action.run({ try await app.dates.save(date, isNew: target.existing == nil) }, onSuccess: {
            Haptics.success()
            dismiss()
        })
    }
}

struct ReminderChips: View {
    @Environment(\.palette) private var palette
    @Binding var selection: Set<Int>

    private static func label(_ days: Int) -> LocalizedStringKey {
        switch days {
        case 0: "On the day"
        case 1: "1 day before"
        case 7: "1 week before"
        case 14: "2 weeks before"
        case 30: "1 month before"
        default: "\(days) days before"
        }
    }

    var body: some View {
        // Wraps onto as many lines as the text size needs.
        FlowLayout(spacing: Space.xs) {
            ForEach(ImportantDate.allowedReminderOffsets, id: \.self) { days in
                let isOn = selection.contains(days)
                let atLimit = selection.count >= ImportantDate.maximumReminders
                Button {
                    if isOn { selection.remove(days) } else if !atLimit { selection.insert(days) }
                } label: {
                    Text(Self.label(days))
                        .font(Typo.callout)
                        .foregroundStyle(isOn ? palette.onAccent : palette.ink)
                        .padding(.horizontal, Space.sm)
                        .frame(minHeight: 36)
                        .background(isOn ? palette.accent : palette.sunken, in: Capsule())
                }
                .opacity(!isOn && atLimit ? 0.4 : 1)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// Lays children out left to right, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}
