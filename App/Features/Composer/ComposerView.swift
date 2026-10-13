import CoupleDesign
import CoupleDomain
import CoupleWidgetUI
import PhotosUI
import SwiftUI

// Screen: Composer
// Purpose: make a note that looks the way you mean it, and get it to your
// partner without ever being unsure whether it went.
// Primary action: Send.
// Layouts weighed: a form with a preview thumbnail (you compose in one place
// and look in another), a multi-step wizard (too much ceremony for "thinking
// of you"), and direct manipulation of the note itself. The last is used: the
// card on screen is the note, you type, draw and place things on it, and the
// tools sit in one tray beneath it that changes with the task.
struct ComposerView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private let request: ComposerRequest
    private let onFinish: (ComposerOutcome) -> Void
    @State private var model: ComposerModel?
    @State private var controller = DrawingController()
    @State private var showingPreview = false
    @State private var showingSchedule = false
    @State private var showingCrop = false
    @State private var confirmingDiscard = false
    @FocusState private var textFocused: Bool

    init(request: ComposerRequest, onFinish: @escaping (ComposerOutcome) -> Void) {
        self.request = request
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    editor(model)
                } else {
                    Color.clear
                }
            }
            .pageBackground(palette)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard model == nil else { return }
            let created = ComposerModel(request: request, storage: app.drafts)
            model = created
            textFocused = created.tool == .text
            // When editing, show the media the note already has.
            if created.isEditingExisting {
                let photo = await app.media.image(path: created.content.photoPath)
                let drawing = await app.media.image(path: created.content.drawingPath, maxPixel: 1024)
                created.setExistingImages(photo: photo, drawing: drawing)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.saveDraftNow() }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Layout

    @ViewBuilder
    private func editor(_ model: ComposerModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Space.sm) {
                    canvas(model)
                    statusLine(model)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.md)
            }
            .scrollDismissesKeyboard(.never)
            .scrollDisabled(model.tool == .draw || model.tool == .stickers)

            if model.tool != .text {
                tray(model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolBar(model)
        }
        .animation(Motion.standard, value: model.tool)
        .toolbar { toolbarContent(model) }
        .sheet(isPresented: $showingPreview) { ComposerPreviewSheet(model: model) }
        .sheet(isPresented: $showingSchedule) { ScheduleSheet(model: model) }
        .fullScreenCover(isPresented: $showingCrop) {
            if let image = model.editingImage {
                PhotoCropView(image: image, aspect: model.photoAspect) { model.applyCrop($0) }
            }
        }
        .confirmationDialog("Discard this note?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                model.discardDraft()
                dismiss()
            }
            Button("Keep as draft") {
                model.saveDraftNow()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.tool) { _, tool in
            textFocused = tool == .text
            if tool != .stickers { model.selectedSticker = nil }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ model: ComposerModel) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                close(model)
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("composer.close")
            .disabled(model.phase == .working)
        }
        ToolbarItem(placement: .principal) {
            Text(title(model))
                .font(Typo.calloutStrong)
                .foregroundStyle(palette.ink)
        }
        ToolbarItemGroup(placement: .confirmationAction) {
            Button {
                textFocused = false
                showingPreview = true
            } label: {
                Image(systemName: "eye")
            }
            .accessibilityLabel(Text("Preview"))
            .accessibilityIdentifier("composer.preview")
            .disabled(model.isEmpty)

            if !isEditingDeliveredNote(model) {
                Button {
                    textFocused = false
                    openSchedule(model)
                } label: {
                    Image(systemName: model.deliverAt == nil ? "clock" : "clock.badge.checkmark")
                }
                .accessibilityLabel(Text("Send later"))
                .accessibilityIdentifier("composer.schedule")
            }

            Button(action: { send(model) }) {
                if model.phase == .working {
                    ProgressView()
                } else {
                    Text(sendTitle(model)).font(Typo.bodyStrong)
                }
            }
            .disabled(!model.canSend)
            .accessibilityIdentifier("composer.send")
        }
    }

    private func isEditingDeliveredNote(_ model: ComposerModel) -> Bool {
        if case .edit = model.mode { true } else { false }
    }

    private func title(_ model: ComposerModel) -> String {
        let name = app.session.partner?.displayName ?? ""
        switch model.mode {
        case .edit: return String(localized: "Edit note")
        case .editScheduled: return String(localized: "Edit surprise")
        default: return String(localized: "To \(name)")
        }
    }

    private func sendTitle(_ model: ComposerModel) -> LocalizedStringKey {
        switch model.mode {
        case .edit, .editScheduled: "Save"
        default: model.deliverAt == nil ? "Send" : "Schedule"
        }
    }

    // MARK: - The note

    private func canvas(_ model: ComposerModel) -> some View {
        @Bindable var model = model
        return GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                NoteCardView(
                    content: model.previewContent, photo: model.photoPreview, drawing: model.existingDrawing,
                    showsText: false, dimsInDarkMode: false
                )
                textLayer(model, side: side)
                DrawingCanvas(
                    drawing: $model.drawing, tool: model.drawingTool, inkHex: Ink.find(model.drawingInk).hex,
                    width: model.strokeWidth, isActive: model.tool == .draw, controller: controller,
                    onChange: { model.drawingChanged() }
                )
                .allowsHitTesting(model.tool == .draw)
                if model.tool == .stickers {
                    StickerEditingLayer(model: model, side: side)
                }
                if model.isLoadingPhoto {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Radius.paper, style: .continuous))
            .paperShadow(palette)
            .frame(maxWidth: .infinity)
            .onAppear { model.canvasSide = side }
            .onChange(of: side) { _, new in model.canvasSide = new }
            .contentShape(Rectangle())
            .onTapGesture {
                if model.tool == .text { textFocused = true }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 440)
    }

    /// The editable text, set in the same face, size and place the finished
    /// note will use, so what is typed is what is sent.
    private func textLayer(_ model: ComposerModel, side: CGFloat) -> some View {
        let layout = model.textLayout
        let ink = layout.onPhoto ? Color.white : Color(hex: Ink.find(model.content.style.ink).hex)
        let field = TextField(
            "",
            text: Binding(get: { model.content.body }, set: { model.setBody($0) }),
            axis: .vertical
        )
        .font(NoteFont.font(model.content.style.typeface, size: side * layout.fontFraction))
        .foregroundStyle(ink)
        .tint(ink)
        .multilineTextAlignment(.center)
        .lineSpacing(side * 0.008)
        .focused($textFocused)
        .padding(.horizontal, side * 0.09)
        .allowsHitTesting(model.tool == .text)
        .accessibilityLabel(Text("Note text"))
        .accessibilityIdentifier("composer.text")
        .background {
            // A real line of text rather than the field's own prompt, which
            // cannot wrap and gets cut off at this size.
            if model.isEmpty, model.tool == .text {
                Text("Write something…")
                    .font(NoteFont.font(model.content.style.typeface, size: side * 0.085))
                    .foregroundStyle(ink.opacity(0.35))
                    .accessibilityHidden(true)
            }
        }

        return Group {
            switch layout.region {
            case .whole:
                field.frame(width: side, height: side * 0.84)
            case .belowFrame:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    field.frame(width: side, height: side * (1 - NoteCardMetrics.framedPhotoFraction - 0.1))
                }
                .padding(.bottom, side * 0.015)
            case .overPhoto:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    field
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .frame(width: side, height: side * 0.34)
                }
                .padding(.bottom, side * 0.03)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ model: ComposerModel) -> some View {
        if case .failed(let error) = model.phase {
            NoticeBanner(error.message, actionTitle: error.isRetryable ? "Try again" : nil) { send(model) }
            if error.isRetryable, !model.isEditingExisting, model.deliverAt == nil {
                Button("Close and keep trying") {
                    // The note stays in the outbox and is retried automatically.
                    model.discardDraft()
                    onFinish(.queued)
                    dismiss()
                }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("composer.queue")
            }
        } else if let error = model.photoError {
            NoticeBanner(error.message)
        } else {
            HStack {
                if let deliverAt = model.deliverAt {
                    Label {
                        Text("Arrives \(deliverAt, format: .dateTime.weekday().day().month().hour().minute())")
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .accessibilityIdentifier("composer.deliveryTime")
                }
                Spacer()
                if model.remainingCharacters <= 40 {
                    Text("\(model.remainingCharacters)")
                        .font(Typo.caption.monospacedDigit())
                        .foregroundStyle(model.remainingCharacters <= 0 ? palette.danger : palette.inkSecondary)
                        .accessibilityLabel(Text("\(model.remainingCharacters) characters left"))
                }
            }
            .frame(minHeight: 20)
        }
    }

    // MARK: - Tools

    private func toolBar(_ model: ComposerModel) -> some View {
        HStack(spacing: 0) {
            ForEach(ComposerTool.allCases) { tool in
                Button {
                    Haptics.selection()
                    model.tool = tool
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: Size.iconControl, weight: .medium))
                        Text(tool.label).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(model.tool == tool ? palette.accent : palette.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: Size.touch + 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                .accessibilityIdentifier("composer.tool.\(tool.rawValue)")
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.top, Space.xxs)
        .background(palette.canvas)
        .overlay(alignment: .top) { Hairline() }
    }

    @ViewBuilder
    private func tray(_ model: ComposerModel) -> some View {
        Group {
            switch model.tool {
            case .text: EmptyView()
            case .draw: DrawTray(model: model, controller: controller)
            case .photo: PhotoTray(model: model, showingCrop: $showingCrop)
            case .style: StyleTray(model: model)
            case .stickers: StickerTray(model: model)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.sm)
        .background(palette.sunken)
    }

    // MARK: - Actions

    private func close(_ model: ComposerModel) {
        textFocused = false
        if model.isEditingExisting || model.isEmpty {
            if model.isEmpty { model.discardDraft() }
            dismiss()
        } else {
            confirmingDiscard = true
        }
    }

    private func openSchedule(_ model: ComposerModel) {
        // Check the plan before the person spends time choosing a moment.
        if model.deliverAt == nil, !model.isEditingExisting,
           !EntitlementRules.canSchedule(pendingCount: app.schedule.pending.count, entitlement: app.entitlement) {
            model.phase = .failed(.scheduledLimitReached)
            return
        }
        showingSchedule = true
    }

    private func send(_ model: ComposerModel) {
        guard model.canSend, let coupleID = app.session.coupleID else { return }
        textFocused = false
        if EntitlementRules.premiumElements(in: model.content.style), !app.entitlement.isPremium {
            app.router.isShowingPaywall = true
            return
        }
        model.phase = .working
        let outgoing = model.outgoing()
        Task {
            do {
                let outcome: ComposerOutcome
                switch model.mode {
                case .edit(let note):
                    _ = try await app.notes.update(note, with: outgoing)
                    outcome = .saved
                case .editScheduled(let message):
                    try await app.schedule.update(message, with: outgoing, deliverAt: model.deliverAt ?? message.deliverAt)
                    outcome = .saved
                case .new, .reply, .surprise:
                    if let deliverAt = model.deliverAt {
                        try await app.schedule.schedule(outgoing, coupleID: coupleID, deliverAt: deliverAt, id: model.sendID)
                        outcome = .scheduled
                    } else {
                        let note = try await app.notes.send(outgoing, coupleID: coupleID, id: model.sendID)
                        outcome = .sent
                        #if DEBUG
                        if let demo = app.demo { Task { await demo.simulatePartnerSeeing(noteID: note.id) } }
                        #endif
                        _ = note
                    }
                }
                // Only now, with the server's acceptance in hand, is it "sent".
                model.discardDraft()
                Haptics.success()
                onFinish(outcome)
                dismiss()
            } catch {
                model.phase = .failed(appError(from: error))
                Haptics.warning()
            }
        }
    }
}

// MARK: - Trays

struct DrawTray: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Bindable var model: ComposerModel
    let controller: DrawingController

    private static let widths: [CGFloat] = [2.5, 4, 7]

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                ForEach(DrawingTool.allCases, id: \.self) { tool in
                    let locked = !EntitlementRules.canUse(tool, with: app.entitlement)
                    Button {
                        if locked {
                            app.router.isShowingPaywall = true
                        } else {
                            Haptics.selection()
                            model.drawingTool = tool
                        }
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: Size.iconControl, weight: .medium))
                            .foregroundStyle(model.drawingTool == tool ? palette.onAccent : palette.ink)
                            .frame(width: Size.touch, height: Size.touch)
                            .background(model.drawingTool == tool ? palette.accent : palette.surface, in: Circle())
                            .overlay(alignment: .topTrailing) { if locked { PremiumMark() } }
                    }
                    .accessibilityLabel(Text(tool.label))
                    .accessibilityAddTraits(model.drawingTool == tool ? .isSelected : [])
                    .accessibilityIdentifier("draw.tool.\(tool.rawValue)")
                }
                Spacer(minLength: Space.xs)
                ForEach(Self.widths, id: \.self) { width in
                    Button {
                        model.strokeWidth = width
                    } label: {
                        Circle()
                            .fill(palette.ink)
                            .frame(width: width * 2.4 + 2, height: width * 2.4 + 2)
                            .frame(width: 36, height: Size.touch)
                            .background(model.strokeWidth == width ? palette.surface : .clear, in: Capsule())
                    }
                    .accessibilityLabel(Text(width == Self.widths[0] ? "Fine line" : width == Self.widths[1] ? "Medium line" : "Thick line"))
                    .accessibilityAddTraits(model.strokeWidth == width ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.md)

            HStack(spacing: Space.xs) {
                SwatchRow(
                    items: Ink.all.map { SwatchItem(id: $0.id, hex: $0.hex, isLocked: !EntitlementRules.canUse($0, with: app.entitlement)) },
                    selection: model.drawingInk,
                    label: { String(localized: "Ink \($0)") }
                ) { id in model.drawingInk = id }

                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .frame(width: Size.touch, height: Size.touch)
                    .disabled(!controller.canUndo)
                    .accessibilityLabel(Text("Undo"))
                    .accessibilityIdentifier("draw.undo")
                Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .frame(width: Size.touch, height: Size.touch)
                    .disabled(!controller.canRedo)
                    .accessibilityLabel(Text("Redo"))
                Button(role: .destructive) { model.clearDrawing() } label: { Image(systemName: "trash") }
                    .frame(width: Size.touch, height: Size.touch)
                    .disabled(!model.hasDrawing)
                    .accessibilityLabel(Text("Clear drawing"))
                    .padding(.trailing, Space.xs)
            }
            .foregroundStyle(palette.ink)
        }
    }
}

struct PhotoTray: View {
    @Environment(\.palette) private var palette
    @Bindable var model: ComposerModel
    @Binding var showingCrop: Bool
    @State private var selection: PhotosPickerItem?

    var body: some View {
        VStack(spacing: Space.sm) {
            // The system picker runs out of process: the app sees only the one
            // photo that is chosen, and needs no photo-library permission.
            PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                Label(model.hasPhoto ? "Choose a different photo" : "Choose a photo", systemImage: "photo.on.rectangle")
                    .font(Typo.bodyStrong)
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, minHeight: Size.touch + 4)
                    .background(palette.surface, in: Capsule())
            }
            .accessibilityIdentifier("photo.pick")

            if model.hasPhoto {
                HStack(spacing: Space.xs) {
                    Picker("Layout", selection: Binding(get: { model.content.style.photoLayout }, set: { model.setPhotoLayout($0) })) {
                        Text("Framed").tag(NoteStyle.PhotoLayout.framed)
                        Text("Full").tag(NoteStyle.PhotoLayout.full)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("photo.layout")

                    Button { showingCrop = true } label: { Image(systemName: "crop") }
                        .frame(width: Size.touch, height: Size.touch)
                        .disabled(!model.canRepositionPhoto)
                        .accessibilityLabel(Text("Position photo"))
                    Button(role: .destructive) { model.removePhoto() } label: { Image(systemName: "trash") }
                        .frame(width: Size.touch, height: Size.touch)
                        .accessibilityLabel(Text("Remove photo"))
                        .accessibilityIdentifier("photo.remove")
                }
                .foregroundStyle(palette.ink)
            } else {
                Text("Only the photo you pick is shared. Location and other details are removed before it’s sent.")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Space.md)
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.setPhoto(from: data)
                } else {
                    model.photoError = .mediaUnreadable
                }
                selection = nil
            }
        }
    }
}

struct StyleTray: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Bindable var model: ComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Picker("Lettering", selection: $model.content.style.typeface) {
                Text("Handwritten").tag(NoteStyle.Typeface.hand)
                Text("Serif").tag(NoteStyle.Typeface.serif)
                Text("Rounded").tag(NoteStyle.Typeface.rounded)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Space.md)
            .accessibilityIdentifier("style.typeface")

            SwatchRow(
                items: Paper.all.map { SwatchItem(id: $0.id, hex: $0.hex, isLocked: !EntitlementRules.canUse($0, with: app.entitlement), pattern: $0.pattern) },
                selection: model.content.style.paper, shape: .paper,
                label: { String(localized: "Paper \($0)") }
            ) { id in model.setPaper(Paper.find(id)) }

            SwatchRow(
                items: Ink.all.map { SwatchItem(id: $0.id, hex: $0.hex, isLocked: !EntitlementRules.canUse($0, with: app.entitlement)) },
                selection: model.content.style.ink,
                label: { String(localized: "Ink \($0)") }
            ) { id in model.content.style.ink = id }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(NoteTemplate.all) { template in
                        let locked = !EntitlementRules.canUse(template, with: app.entitlement)
                        Button {
                            if locked {
                                app.router.isShowingPaywall = true
                            } else {
                                model.apply(template, openingLine: template.openingLine)
                            }
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Text(template.title).font(Typo.calloutStrong)
                                if locked { Image(systemName: "lock.fill").font(.system(size: 10)) }
                            }
                            .foregroundStyle(palette.ink)
                            .padding(.horizontal, Space.sm)
                            .frame(minHeight: 36)
                            .background(palette.surface, in: Capsule())
                        }
                        .accessibilityHint(locked ? Text("Premium") : Text("Applies this look"))
                        .accessibilityIdentifier("style.template.\(template.id)")
                    }
                }
                .padding(.horizontal, Space.md)
            }
        }
    }
}

struct StickerTray: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Bindable var model: ComposerModel

    var body: some View {
        VStack(spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(Sticker.all) { sticker in
                        let locked = !EntitlementRules.canUse(sticker, with: app.entitlement)
                        Button {
                            if locked {
                                app.router.isShowingPaywall = true
                            } else {
                                Haptics.tap()
                                model.addSticker(sticker)
                            }
                        } label: {
                            Image(systemName: sticker.symbol)
                                .font(.system(size: 24))
                                .foregroundStyle(Color(hex: sticker.hex))
                                .frame(width: 52, height: 52)
                                .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                                .overlay(alignment: .topTrailing) { if locked { PremiumMark().offset(x: 4, y: -4) } }
                        }
                        .disabled(!locked && !model.canAddSticker)
                        .accessibilityLabel(Text("Add \(sticker.id) sticker"))
                        .accessibilityIdentifier("sticker.add.\(sticker.id)")
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xxs)
            }

            if let id = model.selectedSticker {
                // The same adjustments the gestures make, as buttons: for
                // VoiceOver, Switch Control, and anyone who prefers a tap.
                HStack(spacing: Space.xs) {
                    trayButton("minus.magnifyingglass", "Smaller") { model.updateSticker(id) { $0.scale -= 0.2 } }
                    trayButton("plus.magnifyingglass", "Larger") { model.updateSticker(id) { $0.scale += 0.2 } }
                    trayButton("rotate.left", "Turn left") { model.updateSticker(id) { $0.rotation -= 15 } }
                    trayButton("rotate.right", "Turn right") { model.updateSticker(id) { $0.rotation += 15 } }
                    Spacer()
                    Button(role: .destructive) { model.removeSticker(id) } label: {
                        Label("Remove", systemImage: "trash").font(Typo.calloutStrong)
                    }
                    .frame(minHeight: Size.touch)
                    .accessibilityIdentifier("sticker.remove")
                }
                .padding(.horizontal, Space.md)
                .foregroundStyle(palette.ink)
            } else {
                Text(model.canAddSticker ? "Tap to add. Then drag, pinch or twist it on the note." : "That’s as many as a note can hold.")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .frame(minHeight: Size.touch)
            }
        }
    }

    private func trayButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Size.touch, height: Size.touch)
                .background(palette.surface, in: Circle())
        }
        .accessibilityLabel(Text(label))
    }
}

/// Stickers on the note while they are being arranged.
struct StickerEditingLayer: View {
    @Environment(\.palette) private var palette
    @Bindable var model: ComposerModel
    let side: CGFloat

    var body: some View {
        ZStack {
            // Tapping empty paper deselects.
            Color.clear.contentShape(Rectangle()).onTapGesture { model.selectedSticker = nil }
            ForEach(model.content.style.stickers) { placement in
                StickerHandle(model: model, placement: placement, side: side)
            }
        }
    }
}

private struct StickerHandle: View {
    @Environment(\.palette) private var palette
    @Bindable var model: ComposerModel
    let placement: StickerPlacement
    let side: CGFloat
    /// Where the sticker was when the current gesture began. Changes are
    /// applied to the model as the fingers move, so the sticker itself (drawn
    /// by the card beneath) follows them.
    @State private var origin: StickerPlacement?

    var body: some View {
        let isSelected = model.selectedSticker == placement.id
        let size = side * 0.13 * placement.scale
        Circle()
            .strokeBorder(isSelected ? palette.accent : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .frame(width: max(size * 1.5, Size.touch), height: max(size * 1.5, Size.touch))
            .contentShape(Circle())
            .position(x: side * placement.x, y: side * placement.y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = begin()
                        model.updateSticker(placement.id) {
                            $0.x = start.x + value.translation.width / side
                            $0.y = start.y + value.translation.height / side
                        }
                    }
                    .onEnded { _ in origin = nil }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { value in
                            let start = begin()
                            model.updateSticker(placement.id) { $0.scale = start.scale * value.magnification }
                        }
                        .onEnded { _ in origin = nil })
                    .simultaneously(with: RotateGesture()
                        .onChanged { value in
                            let start = begin()
                            model.updateSticker(placement.id) { $0.rotation = start.rotation + value.rotation.degrees }
                        }
                        .onEnded { _ in origin = nil })
            )
            .onTapGesture { model.selectedSticker = placement.id }
            .accessibilityLabel(Text("\(placement.sticker) sticker"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func begin() -> StickerPlacement {
        if let origin { return origin }
        origin = placement
        model.selectedSticker = placement.id
        return placement
    }
}

// MARK: - Swatches

struct SwatchItem: Identifiable {
    let id: String
    let hex: String
    let isLocked: Bool
    var pattern: Paper.Pattern = .plain
}

struct SwatchRow: View {
    enum Shape { case ink, paper }

    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    let items: [SwatchItem]
    let selection: String
    var shape: Shape = .ink
    let label: (String) -> String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                ForEach(items) { item in
                    Button {
                        if item.isLocked {
                            app.router.isShowingPaywall = true
                        } else {
                            Haptics.selection()
                            onSelect(item.id)
                        }
                    } label: {
                        swatch(item)
                            .frame(width: Size.touch, height: Size.touch)
                            .overlay(alignment: .topTrailing) { if item.isLocked { PremiumMark() } }
                    }
                    .accessibilityLabel(Text(label(item.id)))
                    .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                    .accessibilityHint(item.isLocked ? Text("Premium") : Text(""))
                    .accessibilityIdentifier("swatch.\(item.id)")
                }
            }
            .padding(.horizontal, Space.md)
        }
    }

    @ViewBuilder
    private func swatch(_ item: SwatchItem) -> some View {
        let selected = selection == item.id
        switch shape {
        case .ink:
            Circle()
                .fill(Color(hex: item.hex))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(palette.hairline, lineWidth: 1))
                .padding(4)
                .overlay(Circle().strokeBorder(selected ? palette.accent : .clear, lineWidth: 2))
        case .paper:
            ZStack {
                Color(hex: item.hex)
                PaperPatternView(pattern: item.pattern, isDark: ColorMath.luminance(hex: item.hex) < 0.3)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? palette.accent : .clear, lineWidth: 2))
        }
    }
}

extension NoteTemplate {
    var title: LocalizedStringKey {
        switch id {
        case "morning": "Good morning"
        case "thinking": "Thinking of you"
        case "luck": "Good luck"
        case "anniversary": "Anniversary"
        case "birthday": "Birthday"
        case "sorry": "I’m sorry"
        case "missing": "Missing you"
        case "datenight": "Date night"
        default: "Template"
        }
    }

    /// A starting line, used only when the note has no words yet.
    var openingLine: String {
        switch id {
        case "morning": String(localized: "Good morning, you.")
        case "thinking": String(localized: "Thinking of you.")
        case "luck": String(localized: "Good luck today. You’ve got this.")
        case "anniversary": String(localized: "Happy anniversary.")
        case "birthday": String(localized: "Happy birthday!")
        case "sorry": String(localized: "I’m sorry.")
        case "missing": String(localized: "I miss you.")
        case "datenight": String(localized: "Date night?")
        default: ""
        }
    }
}

// MARK: - Preview and scheduling sheets

/// Shows the note as the recipient will meet it: in the app, and on their
/// Home Screen and Lock Screen.
struct ComposerPreviewSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let model: ComposerModel

    private var snapshot: WidgetSnapshot {
        WidgetSnapshot(
            state: .note,
            partnerName: app.session.profile?.displayName ?? "",
            themeID: app.session.space.space?.themeID ?? Theme.defaultID,
            accentHex: app.session.space.space?.accentHex,
            style: .note,
            hidesContentOnLockScreen: true,
            note: .init(id: model.sendID, content: model.previewContent, createdAt: Date(), isUnseen: true)
        )
    }

    var body: some View {
        let drawing = model.renderedDrawing().flatMap { ImagePipeline.cgImage(from: $0) } ?? model.existingDrawing
        let images = WidgetImages(photo: model.photoPreview, drawing: drawing)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("How \(app.session.partner?.displayName ?? "your partner") will see it")
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)

                    PaperNote {
                        NoteCardView(content: model.previewContent, photo: images.photo, drawing: images.drawing)
                    }
                    .padding(.horizontal, Space.md)

                    SectionHeading("On their Home Screen")
                    HStack(alignment: .top, spacing: Space.md) {
                        SmallNoteWidgetView(snapshot: snapshot, images: images)
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("If they’ve added the widget, your note appears there. iOS decides exactly when widgets refresh, so it can take a little while.")
                                .font(Typo.caption)
                                .foregroundStyle(palette.inkSecondary)
                        }
                    }
                    MediumNoteWidgetView(snapshot: snapshot, images: images)
                        .frame(height: 158)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    SectionHeading("On their Lock Screen")
                    Text(LockScreenText.headline(for: snapshot))
                        .font(Typo.bodyStrong)
                        .foregroundStyle(palette.ink)
                    Text("What the note says stays hidden there unless they’ve chosen to show it.")
                        .font(Typo.caption)
                        .foregroundStyle(palette.inkSecondary)
                }
                .padding(Space.gutter)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("preview.done")
                }
            }
        }
    }
}

struct ScheduleSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ComposerModel
    @State private var date = Date()

    private var earliest: Date { ScheduleRules.earliestSelectable(now: Date()) }
    private var latest: Date { Date().addingTimeInterval(ScheduleRules.maximumLead) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Send it later")
                        .font(Typo.title)
                        .foregroundStyle(palette.ink)
                    Text("We’ll hold this note and deliver it at the time you choose, even if your phone is off. Until then only you can see it.")
                        .font(Typo.callout)
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    DatePicker("Delivery time", selection: $date, in: earliest...latest)
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("schedule.picker")

                    Label {
                        Text("Times are in your time zone (\(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)). Your partner receives it at that same moment, wherever they are.")
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)

                    Button("Set delivery time") {
                        model.deliverAt = max(date, earliest)
                        if case .failed = model.phase { model.phase = .editing }
                        dismiss()
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("schedule.confirm")

                    if model.deliverAt != nil, !model.isEditingExisting {
                        Button("Send now instead") {
                            model.deliverAt = nil
                            dismiss()
                        }
                        .buttonStyle(.quiet)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("schedule.clear")
                    }
                }
                .padding(Space.gutter)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { date = max(model.deliverAt ?? earliest.addingTimeInterval(3600), earliest) }
    }
}
