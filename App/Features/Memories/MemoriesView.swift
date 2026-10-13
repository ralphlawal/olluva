import CoupleDesign
import CoupleDomain
import PhotosUI
import SwiftUI

// Screen: Memories
// Purpose: a private scrapbook of what the two of you chose to keep.
// Primary action: add a moment.
// Layouts weighed: a photo-library grid (flattens notes, dates and captions
// into thumbnails), a social-style feed of large cards (the wrong feeling
// entirely), and a dated timeline. The timeline is used: months as chapter
// headings, the day in the margin, and each entry set like a page in a
// journal — paper for notes and pictures, plain type for written moments.
struct MemoriesView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @State private var showingAdd = false
    @State private var selected: Memory?

    private var groups: [(month: Date, items: [Memory])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: app.memories.memories) { memory in
            calendar.date(from: DateComponents(year: memory.occurredOn.year, month: memory.occurredOn.month)) ?? .distantPast
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Memories")
                        .font(Typo.display)
                        .foregroundStyle(palette.ink)
                        .accessibilityAddTraits(.isHeader)

                    switch app.memories.loadState {
                    case .idle, .loading:
                        loading
                    case .failed(let error):
                        LoadFailureView(error.message) { reload() }
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.xl)
                    case .loaded:
                        if app.memories.memories.isEmpty {
                            empty
                        } else {
                            timeline
                            footer
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        add()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add a moment"))
                    .accessibilityIdentifier("memories.add")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable { await reloadNow() }
            .sheet(isPresented: $showingAdd) { MomentEditorView(memory: nil) }
            .sheet(item: $selected) { MemoryDetailView(memory: $0) }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: Space.md) {
                    SkeletonBlock().frame(width: 40, height: 44)
                    SkeletonBlock(cornerRadius: Radius.paper).frame(width: 170, height: 170)
                }
            }
        }
    }

    private var empty: some View {
        EmptyStateView(
            symbol: "book.closed",
            title: "Your scrapbook starts here",
            message: "Save a note you want to keep, or write down a moment worth remembering."
        ) {
            Button("Add a moment") { add() }
                .buttonStyle(.primary)
                .frame(maxWidth: 240)
                .accessibilityIdentifier("memories.addFirst")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xxl)
    }

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: Space.xl) {
            ForEach(groups, id: \.month) { group in
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(group.month, format: .dateTime.month(.wide).year())
                        .font(Typo.heading)
                        .foregroundStyle(palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.items) { memory in
                        Button {
                            selected = memory
                        } label: {
                            MemoryRow(memory: memory)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("memories.row")
                        .task { await app.memories.loadMoreIfNeeded(after: memory) }
                    }
                }
            }
            if app.memories.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    /// How full the scrapbook is. Stated plainly; it only mentions Premium
    /// once the limit is actually close.
    @ViewBuilder
    private var footer: some View {
        let limit = app.entitlement.limits.memories
        let count = app.memories.totalCount
        if !app.entitlement.isPremium {
            VStack(alignment: .leading, spacing: Space.xs) {
                Hairline()
                Text("\(count) of \(limit) kept")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                if count >= limit - 5 {
                    Button("Premium keeps up to \(ProductConfiguration.premium.memories)") {
                        app.router.isShowingPaywall = true
                    }
                    .buttonStyle(.quiet)
                }
            }
        }
    }

    private func add() {
        if EntitlementRules.canSaveMemory(currentCount: app.memories.totalCount, entitlement: app.entitlement) {
            showingAdd = true
        } else {
            app.router.isShowingPaywall = true
        }
    }

    private func reload() {
        Task { await reloadNow() }
    }

    private func reloadNow() async {
        if let coupleID = app.session.coupleID { await app.memories.load(coupleID: coupleID) }
    }
}

struct MemoryRow: View {
    @Environment(\.palette) private var palette
    let memory: Memory

    private var hasCard: Bool {
        memory.kind == .note || memory.content.photoPath != nil || memory.content.drawingPath != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            VStack(spacing: 0) {
                Text("\(memory.occurredOn.day)")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(palette.ink)
                Text(memory.occurredOn.date(), format: .dateTime.weekday(.abbreviated))
                    .font(Typo.overline)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.inkSecondary)
            }
            .frame(width: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(memory.occurredOn.date(), format: .dateTime.weekday(.wide).day().month(.wide)))

            VStack(alignment: .leading, spacing: Space.xs) {
                if hasCard {
                    PaperNote(tilt: memory.id.uuidString.first.map { "01234567".contains($0) ? -1.5 : 1.2 } ?? 0, lifted: false) {
                        LoadedNoteCard(content: cardContent, maxPixel: 600)
                    }
                    .frame(maxWidth: 190)
                    .padding(.vertical, Space.xxs)
                }
                if !memory.title.isEmpty {
                    Text(memory.title)
                        .font(Typo.bodyStrong)
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.leading)
                }
                if !memory.caption.isEmpty {
                    Text(memory.caption)
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// A lone photo is shown full-bleed; a saved note is shown as written.
    var cardContent: NoteContent {
        guard memory.kind != .note else { return memory.content }
        var content = memory.content
        content.style.photoLayout = .full
        return content
    }
}

struct MemoryDetailView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var action = ActionState()

    private var current: Memory { app.memories.memories.first { $0.id == memory.id } ?? memory }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(current.occurredOn.date(), format: .dateTime.weekday(.wide).day().month(.wide).year())
                        .overlineStyle(palette)
                    if !current.title.isEmpty {
                        Text(current.title).font(Typo.title).foregroundStyle(palette.ink)
                    }
                    if current.kind == .note || current.content.photoPath != nil || current.content.drawingPath != nil {
                        PaperNote(tilt: 0) {
                            LoadedNoteCard(content: MemoryRow(memory: current).cardContent)
                        }
                        .frame(maxWidth: 460)
                        .frame(maxWidth: .infinity)
                    }
                    if !current.caption.isEmpty {
                        Text(current.caption).font(Typo.body).foregroundStyle(palette.ink)
                    }
                    if let momentID = current.togetherMomentID {
                        // A question you both answered: show what you each said.
                        NavigationLink {
                            TogetherMomentDetailView(momentID: momentID)
                        } label: {
                            HomeLinkRow(symbol: "bubble.left.and.bubble.right", title: "Read both answers")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("memory.together")
                    }
                    if let error = action.error { NoticeBanner(error.message) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.gutter)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("memory.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { editing = true } label: { Label("Edit details", systemImage: "pencil") }
                        Button(role: .destructive) { confirmingDelete = true } label: { Label("Remove", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("More"))
                    .accessibilityIdentifier("memory.more")
                }
            }
            .sheet(isPresented: $editing) { MomentEditorView(memory: current) }
            .confirmationDialog("Remove this memory?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Remove for both of us", role: .destructive) {
                    action.run({ try await app.memories.delete(current) }, onSuccess: { dismiss() })
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It’s removed from the scrapbook you share. This can’t be undone.")
            }
        }
    }
}

/// Adds a moment, or edits the details of an existing memory.
struct MomentEditorView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let memory: Memory?

    @State private var title = ""
    @State private var caption = ""
    @State private var date = Date()
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoPreview: CGImage?
    @State private var action = ActionState()
    @FocusState private var titleFocused: Bool

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty || !caption.trimmingCharacters(in: .whitespaces).isEmpty
            || photoData != nil || memory?.content.isEmpty == false
    }

    var body: some View {
        NavigationStack {
            FormPage(title: memory == nil ? "A moment to keep" : "Edit details", subtitle: nil) {
                VStack(spacing: Space.lg) {
                    LabeledField("What happened") {
                        TextField("Moved in together", text: $title)
                            .focused($titleFocused)
                            .onChange(of: title) { _, value in title = String(value.prefix(Validation.memoryTitleLimit)) }
                            .accessibilityIdentifier("moment.title")
                    }
                    LabeledField("A few words (optional)") {
                        TextField("Forty-one boxes and one confused cat", text: $caption, axis: .vertical)
                            .lineLimit(1...4)
                            .onChange(of: caption) { _, value in caption = String(value.prefix(Validation.memoryCaptionLimit)) }
                            .accessibilityIdentifier("moment.caption")
                    }
                    DatePicker("When", selection: $date, in: ...Date(), displayedComponents: .date)
                        .font(Typo.body)
                        .foregroundStyle(palette.ink)
                        .accessibilityIdentifier("moment.date")

                    if memory == nil {
                        if let photoPreview {
                            HStack(spacing: Space.md) {
                                Image(decorative: photoPreview, scale: 1)
                                    .resizable().scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.paper, style: .continuous))
                                Button("Remove photo", role: .destructive) {
                                    photoData = nil
                                    self.photoPreview = nil
                                }
                                .buttonStyle(.quietDestructive)
                                Spacer()
                            }
                        } else {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("Add a photo", systemImage: "photo")
                            }
                            .buttonStyle(.secondary)
                            .accessibilityIdentifier("moment.photo")
                        }
                    }
                }
                .disabled(action.isRunning)

                if let error = action.error {
                    NoticeBanner(error.message, actionTitle: error == .memoryLimitReached ? "See Premium" : nil) {
                        app.router.isShowingPaywall = true
                    }
                }

                Button(memory == nil ? "Keep this" : "Save", action: save)
                    .buttonStyle(.primary(isLoading: action.isRunning))
                    .disabled(!canSave || action.isRunning)
                    .accessibilityIdentifier("moment.save")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            if let memory {
                title = memory.title
                caption = memory.caption
                date = memory.occurredOn.date()
            } else {
                titleFocused = true
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = ImagePipeline.editingImage(from: data),
                   let jpeg = ImagePipeline.croppedJPEG(
                       image, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                       maxPixel: ImagePipeline.notePhotoPixels
                   ) {
                    photoData = jpeg
                    photoPreview = ImagePipeline.cgImage(from: jpeg)
                } else {
                    action.error = .mediaUnreadable
                }
                pickerItem = nil
            }
        }
    }

    private func save() {
        let day = DayDate(date)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        action.run({
            if let memory {
                try await app.memories.update(memory, title: cleanTitle, caption: cleanCaption, occurredOn: day)
            } else {
                try await app.memories.add(
                    NewMoment(title: cleanTitle, caption: cleanCaption, occurredOn: day), photo: photoData, media: app.media
                )
            }
        }, onSuccess: {
            Haptics.success()
            dismiss()
        })
    }
}
