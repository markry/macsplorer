import AppKit
import QuickLookThumbnailing

/// Generates content thumbnails (image previews, PDF/first-page, video posters)
/// for the icon grid, off the main thread, with a small in-memory cache. Callers
/// show the file's regular `NSWorkspace` icon immediately and swap in a real
/// thumbnail only if/when one arrives — so non-previewable files keep their crisp
/// type icon rather than a generic placeholder.
final class Thumbnailer {
    static let shared = Thumbnailer()

    private let generator = QLThumbnailGenerator.shared
    private let cache = NSCache<NSString, NSImage>()

    private func key(_ url: URL, _ edge: CGFloat) -> NSString {
        "\(url.path)|\(Int(edge))" as NSString
    }

    /// Cached thumbnail if we already have one at this size (synchronous), else nil.
    func cached(for url: URL, edge: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, edge))
    }

    /// Request a thumbnail of `edge` points. `completion` runs on the main thread
    /// only when a real thumbnail is produced (never for a plain failure), so the
    /// caller's icon placeholder stays put otherwise.
    func thumbnail(for url: URL, edge: CGFloat, scale: CGFloat,
                   completion: @escaping (NSImage) -> Void) {
        let cacheKey = key(url, edge)
        if let hit = cache.object(forKey: cacheKey) { completion(hit); return }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: edge, height: edge),
            scale: scale,
            representationTypes: .thumbnail)
        generator.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else { return }
            let image = representation.nsImage
            self?.cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
