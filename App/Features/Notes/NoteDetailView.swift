import CoupleDesign
import CoupleDomain
import SwiftUI

// Screen: Note
// Purpose: give one note your full attention, and let you answer it.
// Primary action: reply (for a note you received) or nothing at all (for one
// you sent — there you mostly want to know it arrived).
// Layouts weighed: a chat-style thread (turns keepsakes into a message log),
// a full-screen immersive card with hidden controls (pretty, but hides the
// reply), and a sheet with the note on top and its few actions beneath. The
// sheet is used: it keeps the note large, keeps Home one swipe away, and puts
// reacting and replying where a thumb already is.
struct NoteDetailView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    let note: Note
    let compose: (ComposerRequest) -> Void
    @State private var action = ActionState()
    @State private var confirmingDelete = false
    @State private var confirmingReport = false
    @State private var playsEffect = false
    @State private var toast: LocalizedStringKey?

    /// The freshest copy: the note may be edited, seen or deleted while open.
    private var current: Note? { app.notes.note(id: note.id) }
    private var isMine: Bool { note.authorID == app.session.userID }
    private var author: Profile? { isMine ? app.session.profile : app.session.partner }

    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    content(current)
                } else {
                    // Deleted by its author while it was on screen.
                    EmptyStateView(
                        symbol: "note.text.badge.plus", title: "This note is gone",
                        message: "It was removed by the person who wrote it."
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .pageBackground(palette)
            .toast($toast)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("note.done")
                }
                if let current, !isMine {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) {
                                confirmingReport = true
                            } label: {
                                Label("Report this note", systemImage: "exclamationmark.bubble")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text("More"))
                        .accessibilityIdentifier("note.more")
                        .confirmationDialog("Report this note?", isPresented: $confirmingReport, titleVisibility: .visible) {
                            Button("Report", role: .destructive) {
                                action.run({ try await app.backend.notes.report(noteID: current.id) }, onSuccess: {
                                    toast = "Reported. Thank you."
                                })
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("We’ll look at it. If someone is making you uncomfortable, you can also leave this space and block them in Settings.")
                        }
                    }
                }
                if let current, isMine {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                compose(ComposerRequest(mode: .edit(current)))
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                confirmingDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text("More"))
                        .accessibilityIdentifier("note.more")
                    }
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete for both of us", role: .destructive) {
                    guard let current else { return }
                    action.run({ try await app.notes.delete(current) }, onSuccess: { dismiss() })
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It disappears from \(app.session.partner?.displayName ?? "your partner")’s phone and widgets too. If it was saved to Memories, that copy stays.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: note.id) {
            if let current { await app.notes.markSeen(current, by: app.session.userID) }
        }
    }

    private func content(_ note: Note) -> some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    ProfileAvatar(profile: author, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isMine ? String(localized: "You") : author?.displayName ?? "")
                            .font(Typo.bodyStrong)
                            .foregroundStyle(palette.ink)
                        HStack(spacing: Space.xxs) {
                            Text(note.createdAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                            if note.isEdited { Text("· Edited") }
                        }
                        .font(Typo.caption)
                        .foregroundStyle(palette.inkSecondary)
                    }
                    Spacer()
                    if note.origin == .scheduled {
                        Label("Surprise", systemImage: "gift")
                            .font(Typo.caption.weight(.semibold))
                            .foregroundStyle(palette.highlight)
                    }
                }
                .accessibilityElement(children: .combine)

                PaperNote(tilt: 0) {
                    LoadedNoteCard(content: note.content)
                }
                .frame(maxWidth: 460)
                .overlay {
                    if playsEffect, let effect = note.style.effect {
                        NoteEffectView(effect: effect)
                    }
                }
                .task(id: note.id) {
                    // Once, each time the note is opened.
                    guard note.style.effect != nil else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    playsEffect = true
                    try? await Task.sleep(for: .seconds(NoteEffectView.duration + 0.2))
                    playsEffect = false
                }

                // At the largest text sizes a card's lettering cannot grow with
                // the setting, so the words are also given as ordinary text.
                if typeSize.isAccessibilitySize, !note.body.isEmpty {
                    Text(note.body)
                        .font(Typo.body)
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = action.error { NoticeBanner(error.message) }

                if isMine {
                    sentStatus(note)
                } else {
                    reactions(note)
                    Button {
                        compose(ComposerRequest(mode: .reply(to: note)))
                    } label: {
                        Label("Write back", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("note.reply")
                }

                saveButton(note)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
    }

    private func reactions(_ note: Note) -> some View {
        let mine = app.notes.reaction(on: note.id, by: app.session.userID)
        return HStack(spacing: 0) {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                Button {
                    guard let userID = app.session.userID else { return }
                    Haptics.selection()
                    action.run { try await app.notes.setReaction(mine == kind ? nil : kind, on: note, by: userID) }
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(mine == kind ? palette.onAccent : palette.inkSecondary)
                        .frame(width: Size.touch, height: Size.touch)
                        .background(mine == kind ? palette.highlight : .clear, in: Circle())
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(Text(kind.label))
                .accessibilityAddTraits(mine == kind ? .isSelected : [])
                .accessibilityIdentifier("note.reaction.\(kind.rawValue)")
            }
        }
        .padding(.vertical, Space.xxs)
        .background(palette.sunken, in: Capsule())
    }

    private func sentStatus(_ note: Note) -> some View {
        let partnerName = app.session.partner?.displayName ?? ""
        let reaction = app.notes.reaction(on: note.id, by: app.session.partner?.id)
        return HStack(spacing: Space.sm) {
            Image(systemName: note.seenAt == nil ? "paperplane" : "checkmark.circle")
                .foregroundStyle(palette.inkSecondary)
                .accessibilityHidden(true)
            if let seenAt = note.seenAt {
                Text("\(partnerName) saw this \(seenAt, format: .relative(presentation: .named))")
            } else {
                Text("Delivered. \(partnerName) hasn’t opened it yet.")
            }
            Spacer(minLength: 0)
            if let reaction {
                Image(systemName: reaction.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(palette.highlight)
                    .accessibilityLabel(Text("Reacted: \(reaction.label)"))
            }
        }
        .font(Typo.callout)
        .foregroundStyle(palette.ink)
        .padding(Space.md)
        .background(palette.sunken, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("note.status")
    }

    private func saveButton(_ note: Note) -> some View {
        let saved = app.memories.isSaved(noteID: note.id)
        return Button {
            action.run({ try await app.memories.saveNote(note) }, onSuccess: {
                Haptics.success()
                toast = "Saved to Memories"
            })
        } label: {
            Label(saved ? "Saved to Memories" : "Save to Memories", systemImage: saved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.secondary)
        .disabled(saved || action.isRunning)
        .accessibilityIdentifier("note.save")
    }
}

/// Every note the two of you have exchanged, newest first.
struct NotesHistoryView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.md)]

    var body: some View {
        let notes = app.notes.feed.visible
        ScrollView {
            if notes.isEmpty {
                EmptyStateView(
                    symbol: "tray", title: "Nothing here yet",
                    message: "Notes you send each other collect here."
                )
                .padding(.top, Space.xxl)
            } else {
                LazyVGrid(columns: columns, spacing: Space.lg) {
                    ForEach(notes) { note in
                        Button {
                            app.router.presentedNoteID = note.id
                        } label: {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                LoadedNoteCard(content: note.content, maxPixel: 500)
                                    .paperShadow(palette, lifted: false)
                                HStack(spacing: Space.xxs) {
                                    Text(note.authorID == app.session.userID ? String(localized: "You") : app.session.partner?.displayName ?? "")
                                        .font(Typo.caption.weight(.semibold))
                                        .foregroundStyle(palette.ink)
                                    Text(note.createdAt, format: .dateTime.day().month())
                                        .font(Typo.caption)
                                        .foregroundStyle(palette.inkSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .task {
                            if note.id == notes.last?.id { await app.notes.loadMore() }
                        }
                    }
                }
                .padding(Space.gutter)
                if app.notes.isLoadingMore { ProgressView().padding() }
            }
        }
        .pageBackground(palette)
        .navigationTitle("Earlier notes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
