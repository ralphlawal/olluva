import CoupleDesign
import CoupleDomain
import PencilKit
import SwiftUI

/// Lets SwiftUI drive undo and redo on the PencilKit canvas.
@MainActor
@Observable
final class DrawingController {
    fileprivate weak var canvas: PKCanvasView?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func undo() {
        canvas?.undoManager?.undo()
        refresh()
    }

    func redo() {
        canvas?.undoManager?.redo()
        refresh()
    }

    fileprivate func refresh() {
        canUndo = canvas?.undoManager?.canUndo ?? false
        canRedo = canvas?.undoManager?.canRedo ?? false
    }
}

/// A transparent PencilKit layer laid exactly over the note card. Finger and
/// Apple Pencil both draw; it takes no touches unless drawing is the active tool.
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let tool: DrawingTool
    let inkHex: String
    let width: CGFloat
    let isActive: Bool
    let controller: DrawingController
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        // The ink colour is absolute: PencilKit must not invert it in dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        canvas.accessibilityLabel = String(localized: "Drawing area")
        canvas.accessibilityTraits = .allowsDirectInteraction
        controller.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.drawing != drawing {
            context.coordinator.isApplyingExternalChange = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalChange = false
        }
        canvas.isUserInteractionEnabled = isActive
        // Exposed to assistive technologies only while drawing; otherwise it
        // would sit in front of the note's text field.
        canvas.isAccessibilityElement = isActive
        canvas.tool = Self.pencilKitTool(tool, hex: inkHex, width: width)
    }

    static func pencilKitTool(_ tool: DrawingTool, hex: String, width: CGFloat) -> PKTool {
        let color = UIColor(Color(hex: hex))
        switch tool {
        case .pen: return PKInkingTool(.pen, color: color, width: width)
        case .marker: return PKInkingTool(.marker, color: color.withAlphaComponent(0.7), width: width * 3)
        case .pencil: return PKInkingTool(.pencil, color: color, width: width * 1.4)
        case .fountain: return PKInkingTool(.fountainPen, color: color, width: width * 1.6)
        case .fineliner: return PKInkingTool(.monoline, color: color, width: width * 0.8)
        case .watercolour: return PKInkingTool(.watercolor, color: color, width: width * 5)
        case .crayon: return PKInkingTool(.crayon, color: color, width: width * 3)
        case .eraser: return PKEraserTool(.vector)
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        var isApplyingExternalChange = false

        init(_ parent: DrawingCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalChange else { return }
            parent.drawing = canvasView.drawing
            parent.controller.refresh()
            parent.onChange()
        }
    }
}

extension DrawingTool {
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .pencil: "pencil"
        case .fountain: "pencil.tip.crop.circle"
        case .fineliner: "pencil.line"
        case .watercolour: "paintbrush.pointed"
        case .crayon: "scribble.variable"
        case .eraser: "eraser"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .pencil: "Pencil"
        case .fountain: "Fountain pen"
        case .fineliner: "Fine liner"
        case .watercolour: "Watercolour"
        case .crayon: "Crayon"
        case .eraser: "Eraser"
        }
    }
}

// MARK: - Photo crop

/// Positions a photo inside the shape it will have on the note. The photo
/// always covers the frame: it can be moved and zoomed, never left with gaps.
struct PhotoCropView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let image: CGImage
    let aspect: CGFloat
    let onDone: (CGRect) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let frame = frameSize(in: proxy.size)
                let base = baseSize(for: frame)
                let liveZoom = clampedZoom(zoom * pinch)
                let liveOffset = clampedOffset(
                    CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                    zoom: liveZoom, base: base, frame: frame
                )
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: base.width * liveZoom, height: base.height * liveZoom)
                        .offset(liveOffset)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .overlay(Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .updating($drag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    offset = clampedOffset(
                                        CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                                        zoom: zoom, base: base, frame: frame
                                    )
                                }
                                .simultaneously(with: MagnifyGesture()
                                    .updating($pinch) { value, state, _ in state = value.magnification }
                                    .onEnded { value in
                                        zoom = clampedZoom(zoom * value.magnification)
                                        offset = clampedOffset(offset, zoom: zoom, base: base, frame: frame)
                                    })
                        )
                        .accessibilityLabel(Text("Photo. Drag to move, pinch to zoom."))
                        .accessibilityAdjustableAction { direction in
                            // VoiceOver users zoom with swipe up / down.
                            zoom = clampedZoom(zoom + (direction == .increment ? 0.25 : -0.25))
                            offset = clampedOffset(offset, zoom: zoom, base: base, frame: frame)
                        }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onDone(cropRect(zoom: zoom, offset: offset, base: base, frame: frame))
                            dismiss()
                        }
                        .accessibilityIdentifier("crop.done")
                    }
                }
            }
            .navigationTitle("Position photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func frameSize(in available: CGSize) -> CGSize {
        let width = min(available.width - Space.gutter * 2, (available.height - Space.xxl * 2) * aspect)
        return CGSize(width: max(1, width), height: max(1, width / aspect))
    }

    /// The image's size when it just covers the frame.
    private func baseSize(for frame: CGSize) -> CGSize {
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        return imageAspect > aspect
            ? CGSize(width: frame.height * imageAspect, height: frame.height)
            : CGSize(width: frame.width, height: frame.width / imageAspect)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), 4)
    }

    private func clampedOffset(_ value: CGSize, zoom: CGFloat, base: CGSize, frame: CGSize) -> CGSize {
        let limitX = max(0, (base.width * zoom - frame.width) / 2)
        let limitY = max(0, (base.height * zoom - frame.height) / 2)
        return CGSize(width: min(max(value.width, -limitX), limitX), height: min(max(value.height, -limitY), limitY))
    }

    /// The visible region, in the image's own pixels.
    private func cropRect(zoom: CGFloat, offset: CGSize, base: CGSize, frame: CGSize) -> CGRect {
        let scale = CGFloat(image.width) / (base.width * zoom)
        let originX = (base.width * zoom - frame.width) / 2 - offset.width
        let originY = (base.height * zoom - frame.height) / 2 - offset.height
        return CGRect(x: originX * scale, y: originY * scale, width: frame.width * scale, height: frame.height * scale)
    }
}
