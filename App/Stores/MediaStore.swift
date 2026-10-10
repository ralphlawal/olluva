import CoreGraphics
import CoupleDomain
import CoupleWidgetUI
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Fetches, decodes and caches private media. Images are only ever obtained
/// through the authorised backend; the cache holds copies for the signed-in
/// account and is wiped on sign-out and unlinking.
@MainActor
final class MediaStore {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let backend: Backend
    private let memory = NSCache<NSString, Box>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let directory: URL

    init(backend: Backend) {
        self.backend = backend
        memory.countLimit = 60
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A decoded image no larger than `maxPixel` on its longest side.
    func image(path: String?, maxPixel: Int = 1400) async -> CGImage? {
        guard let path else { return nil }
        let key = "\(path)#\(maxPixel)" as NSString
        if let cached = memory.object(forKey: key) { return cached.image }
        guard let data = await data(path: path) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            WidgetSnapshotStore.downsampledImage(from: data, maxPixel: maxPixel)
        }.value
        if let image { memory.setObject(Box(image), forKey: key) }
        return image
    }

    /// The raw bytes, from disk if we have them, otherwise downloaded once
    /// however many views ask at the same time.
    func data(path: String?) async -> Data? {
        guard let path else { return nil }
        let file = fileURL(for: path)
        if let data = try? Data(contentsOf: file) { return data }
        if let running = inFlight[path] { return await running.value }

        let isAvatar = path.hasSuffix("/avatar.jpg")
        let task = Task<Data?, Never> { [backend] in
            do {
                return isAvatar ? try await backend.media.downloadAvatar(path: path) : try await backend.media.download(path: path)
            } catch {
                Diagnostics.failure(Diagnostics.media, "download", error)
                return nil
            }
        }
        inFlight[path] = task
        let data = await task.value
        inFlight[path] = nil
        if let data { write(data, to: file) }
        return data
    }

    /// Keeps a copy of something this device just uploaded, so it does not
    /// have to be downloaded straight back.
    func prime(_ data: Data, for path: String) {
        write(data, to: fileURL(for: path))
    }

    /// Avatars are mutable (same path, new picture), so drop the old copy.
    func invalidate(path: String) {
        try? FileManager.default.removeItem(at: fileURL(for: path))
        memory.removeAllObjects()
    }

    func clear() {
        memory.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for path: String) -> URL {
        directory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    private func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Turns whatever the photo picker hands over into something safe to send:
/// upright, a sensible size, under the upload limit, and stripped of metadata.
enum ImagePipeline {
    /// The longest side of a note photo, in pixels.
    static let notePhotoPixels = 1400
    static let avatarPixels = 400
    /// Working size for the crop screen: big enough to zoom, small enough to stay cheap.
    static let editingPixels = 2400

    static func editingImage(from data: Data) -> CGImage? {
        WidgetSnapshotStore.downsampledImage(from: data, maxPixel: editingPixels)
    }

    /// Crops `image` to `rect` (in the image's pixel space) and encodes a JPEG
    /// whose longest side is at most `maxPixel`. Re-encoding drops EXIF,
    /// including any location the original carried.
    static func croppedJPEG(_ image: CGImage, rect: CGRect, maxPixel: Int, limit: Int = MediaPath.maximumMediaBytes) -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isEmpty, let cropped = image.cropping(to: clipped) else { return nil }

        let scale = min(1, CGFloat(maxPixel) / CGFloat(max(cropped.width, cropped.height)))
        let size = CGSize(width: (CGFloat(cropped.width) * scale).rounded(), height: (CGFloat(cropped.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.82, 0.7, 0.55, 0.4] {
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= limit { return data }
        }
        return nil
    }

    /// The largest centred rectangle of the given aspect ratio.
    static func centeredRect(in image: CGImage, aspect: CGFloat) -> CGRect {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Whole pixels, so a square request yields an exactly square image.
        if width / height > aspect {
            let cropWidth = (height * aspect).rounded(.down)
            return CGRect(x: ((width - cropWidth) / 2).rounded(.down), y: 0, width: cropWidth, height: height)
        }
        let cropHeight = (width / aspect).rounded(.down)
        return CGRect(x: 0, y: ((height - cropHeight) / 2).rounded(.down), width: width, height: cropHeight)
    }

    static func avatarJPEG(from data: Data) -> Data? {
        guard let image = WidgetSnapshotStore.downsampledImage(from: data, maxPixel: avatarPixels * 2) else { return nil }
        return croppedJPEG(image, rect: centeredRect(in: image, aspect: 1), maxPixel: avatarPixels, limit: MediaPath.maximumAvatarBytes)
    }

    static func cgImage(from data: Data?) -> CGImage? {
        guard let data else { return nil }
        return WidgetSnapshotStore.downsampledImage(from: data, maxPixel: notePhotoPixels)
    }
}
