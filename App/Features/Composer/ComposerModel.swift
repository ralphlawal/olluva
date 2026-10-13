import CoupleDesign
import CoupleDomain
import Observation
import PencilKit
import SwiftUI

/// What the composer has been opened to do.
struct ComposerRequest: Identifiable {
    enum Mode {
        case new
        case reply(to: Note)
        case edit(Note)
        case editScheduled(ScheduledMessage)
        /// A new note that starts with a delivery time already chosen.
        case surprise
    }

    let id = UUID()
    var mode: Mode
    var startingTool: ComposerTool = .text
}

enum ComposerTool: String, CaseIterable, Identifiable {
    case text, draw, photo, style, stickers

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .draw: "scribble.variable"
        case .photo: "photo"
        case .style: "swatchpalette"
        case .stickers: "face.smiling"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .text: "Words"
        case .draw: "Draw"
        case .photo: "Photo"
        case .style: "Style"
        case .stickers: "Stickers"
        }
    }
}

enum ComposerOutcome {
    case sent, scheduled, saved, queued
}

/// The state of one composition. Everything the person has done lives here
/// and is mirrored to disk as a draft, so nothing is lost if the composer, or
/// the app, goes away before they send.
@MainActor
@Observable
final class ComposerModel {
    enum Phase: Equatable {
        case editing
        case working
        case failed(AppError)
    }

    let mode: ComposerRequest.Mode
    var content: NoteContent
    var tool: ComposerTool
    var phase: Phase = .editing

    // Photo
    /// The picked image at editing size; kept so it can be repositioned.
    private(set) var photoSource: CGImage?
    private(set) var photoSourceData: Data?
    /// The cropped JPEG that will be uploaded, and its decoded preview.
    private(set) var photoData: Data?
    private(set) var photoPreview: CGImage?
    var isLoadingPhoto = false
    var photoError: AppError?

    // Drawing
    var drawing = PKDrawing()
    var canvasSide: CGFloat = 0
    var drawingTool: DrawingTool = .pen
    var drawingInk = Ink.defaultID
    var strokeWidth: CGFloat = 4
    /// A drawing that came with the note being edited; new strokes go on top.
    private(set) var existingDrawing: CGImage?

    // Stickers
    var selectedSticker: UUID?

    // Scheduling
    var deliverAt: Date?

    /// Fixed for the life of this composition so a retried send is recognised
    /// by the server as the same note.
    let sendID = UUID()

    private let storage: DraftStorage
    private let usesDraft: Bool
    private var saveTask: Task<Void, Never>?

    init(request: ComposerRequest, storage: DraftStorage) {
        mode = request.mode
        tool = request.startingTool
        self.storage = storage

        switch request.mode {
        case .new, .reply, .surprise:
            usesDraft = true
            if let draft = storage.load() {
                content = draft.content
                if draft.hasPhoto, let source = storage.file(DraftStorage.photoSourceName) {
                    photoSourceData = source
                    photoSource = ImagePipeline.editingImage(from: source)
                    photoData = storage.file(DraftStorage.photoName)
                    photoPreview = ImagePipeline.cgImage(from: photoData)
                }
                if draft.hasDrawing, let data = storage.file(DraftStorage.drawingName),
                   let restored = try? PKDrawing(data: data) {
                    drawing = restored
                }
                content.photoPath = nil
                content.drawingPath = nil
            } else {
                content = NoteContent()
            }
            if case .surprise = request.mode {
                deliverAt = ScheduleRules.earliestSelectable(now: Date().addingTimeInterval(3600))
            }
        case .edit(let note):
            usesDraft = false
            content = note.content
        case .editScheduled(let message):
            usesDraft = false
            content = message.content
            deliverAt = message.deliverAt
        }
    }

    // MARK: - Derived state

    var isEditingExisting: Bool {
        switch mode {
        case .edit, .editScheduled: true
        default: false
        }
    }

    var hasPhoto: Bool { photoPreview != nil || content.photoPath != nil }
    var hasDrawing: Bool { !drawing.strokes.isEmpty || content.drawingPath != nil }

    var isEmpty: Bool {
        content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasPhoto && !hasDrawing
    }

    var remainingCharacters: Int { Validation.noteBodyLimit - content.body.count }
    var canSend: Bool { !isEmpty && remainingCharacters >= 0 && phase != .working }

    var textLayout: NoteCardMetrics.TextLayout {
        NoteCardMetrics.textLayout(for: content, hasPhoto: hasPhoto)
    }

    /// The content as the recipient will see it, for live preview.
    var previewContent: NoteContent {
        var preview = content
        if photoPreview != nil { preview.photoPath = "preview" }
        return preview
    }

    // MARK: - Text

    func setBody(_ text: String) {
        // Typing past the limit is allowed to show the count going negative
        // briefly on paste; the hard stop is here.
        content.body = String(text.prefix(Validation.noteBodyLimit))
        scheduleSave()
    }

    // MARK: - Style

    func setPaper(_ paper: Paper) {
        content.style.paper = paper.id
        // Dark paper with dark ink (or the reverse) would be unreadable; move
        // to a legible default, but only if the current ink would not show.
        let ink = Ink.find(content.style.ink)
        let inkIsLight = ColorMath.luminance(hex: ink.hex) > 0.6
        if paper.isDark, !inkIsLight { content.style.ink = Ink.lightID }
        if !paper.isDark, inkIsLight { content.style.ink = Ink.defaultID }
        scheduleSave()
    }

    func apply(_ template: NoteTemplate, openingLine: String) {
        content.style = template.style
        // New ids so stickers stay independently editable.
        content.style.stickers = template.style.stickers.map {
            StickerPlacement(sticker: $0.sticker, x: $0.x, y: $0.y, scale: $0.scale, rotation: $0.rotation)
        }
        if content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = openingLine
        }
        scheduleSave()
    }

    // MARK: - Stickers

    var canAddSticker: Bool { content.style.stickers.count < Validation.maximumStickers }

    func addSticker(_ sticker: Sticker) {
        guard canAddSticker else { return }
        // Offset each new one a little so they do not land exactly on top of each other.
        let offset = Double(content.style.stickers.count % 4) * 0.07
        let placement = StickerPlacement(sticker: sticker.id, x: 0.5 + offset - 0.1, y: 0.78 - offset)
        content.style.stickers.append(placement)
        selectedSticker = placement.id
        scheduleSave()
    }

    func updateSticker(_ id: UUID, _ change: (inout StickerPlacement) -> Void) {
        guard let index = content.style.stickers.firstIndex(where: { $0.id == id }) else { return }
        change(&content.style.stickers[index])
        content.style.stickers[index].x = min(max(content.style.stickers[index].x, 0.04), 0.96)
        content.style.stickers[index].y = min(max(content.style.stickers[index].y, 0.04), 0.96)
        content.style.stickers[index].scale = min(max(content.style.stickers[index].scale, 0.5), 2.6)
        scheduleSave()
    }

    func removeSticker(_ id: UUID) {
        content.style.stickers.removeAll { $0.id == id }
        if selectedSticker == id { selectedSticker = nil }
        scheduleSave()
    }

    // MARK: - Photo

    /// The shape the photo is cropped to for the current layout.
    var photoAspect: CGFloat {
        content.style.photoLayout == .full ? 1 : CGFloat(0.86 / NoteCardMetrics.framedPhotoFraction)
    }

    func setPhoto(from data: Data) async {
        isLoadingPhoto = true
        photoError = nil
        defer { isLoadingPhoto = false }
        let image = await Task.detached(priority: .userInitiated) { ImagePipeline.editingImage(from: data) }.value
        guard let image else {
            photoError = .mediaUnreadable
            return
        }
        // Keep a size-bounded copy of the source for the draft, not the
        // multi-megabyte original.
        let source = ImagePipeline.croppedJPEG(
            image, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height), maxPixel: ImagePipeline.editingPixels
        )
        photoSource = image
        photoSourceData = source
        content.photoPath = nil
        applyCrop(ImagePipeline.centeredRect(in: image, aspect: photoAspect))
    }

    func applyCrop(_ rect: CGRect) {
        guard let photoSource else { return }
        guard let data = ImagePipeline.croppedJPEG(photoSource, rect: rect, maxPixel: ImagePipeline.notePhotoPixels) else {
            photoError = .mediaTooLarge
            return
        }
        photoData = data
        photoPreview = ImagePipeline.cgImage(from: data)
        scheduleSave()
    }

    func setPhotoLayout(_ layout: NoteStyle.PhotoLayout) {
        guard content.style.photoLayout != layout else { return }
        content.style.photoLayout = layout
        // The frame changed shape, so the crop has to follow it.
        if let photoSource { applyCrop(ImagePipeline.centeredRect(in: photoSource, aspect: photoAspect)) }
        scheduleSave()
    }

    var canRepositionPhoto: Bool { photoSource != nil }
    var editingImage: CGImage? { photoSource }

    func removePhoto() {
        photoSource = nil
        photoSourceData = nil
        photoData = nil
        photoPreview = nil
        content.photoPath = nil
        scheduleSave()
    }

    func setExistingImages(photo: CGImage?, drawing: CGImage?) {
        if photoPreview == nil, content.photoPath != nil { photoPreview = photo }
        existingDrawing = drawing
    }

    // MARK: - Drawing

    func drawingChanged() {
        scheduleSave()
    }

    func clearDrawing() {
        drawing = PKDrawing()
        existingDrawing = nil
        content.drawingPath = nil
        scheduleSave()
    }

    /// Flattens the strokes (over any earlier drawing) to a transparent PNG
    /// at a fixed size, independent of the phone it was drawn on.
    func renderedDrawing() -> Data? {
        guard !drawing.strokes.isEmpty, canvasSide > 0 else { return nil }
        let pixels: CGFloat = 1024
        let bounds = CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide)
        var strokes: UIImage?
        // Ink is chosen for the paper, not for the phone's appearance.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            strokes = drawing.image(from: bounds, scale: pixels / canvasSide)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: pixels, height: pixels)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            if let existingDrawing {
                UIImage(cgImage: existingDrawing).draw(in: CGRect(origin: .zero, size: size))
            }
            strokes?.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Output

    /// The note as it should be sent: content plus any media that needs uploading.
    func outgoing() -> OutgoingNote {
        var result = content
        let drawingData = renderedDrawing()
        if drawingData != nil { result.drawingPath = nil }
        if photoData != nil { result.photoPath = nil }
        result.body = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return OutgoingNote(content: result, photo: photoData, drawing: drawingData)
    }

    // MARK: - Draft

    private func scheduleSave() {
        guard usesDraft else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    func saveDraftNow() {
        guard usesDraft else { return }
        saveTask?.cancel()
        if isEmpty, content.style == NoteStyle() {
            storage.clear()
            return
        }
        let draft = ComposerDraft(content: content, hasPhoto: photoData != nil, hasDrawing: !drawing.strokes.isEmpty, savedAt: Date())
        storage.save(draft, files: [
            DraftStorage.photoName: photoData,
            DraftStorage.photoSourceName: photoData == nil ? nil : photoSourceData,
            DraftStorage.drawingName: drawing.strokes.isEmpty ? nil : drawing.dataRepresentation(),
        ])
    }

    func discardDraft() {
        saveTask?.cancel()
        if usesDraft { storage.clear() }
    }
}
