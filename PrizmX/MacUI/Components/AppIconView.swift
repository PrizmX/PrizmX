import AppKit
import SwiftUI

/// Resolves a macOS app icon from a bundle ID and/or executable path.
///
/// Icons stay in the **main app**. The packet tunnel never loads bitmaps
/// (they would blow the ~50 MB extension budget). Thumbnails are cached at 32px.
enum AppIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 32 * 32 * 4
        return cache
    }()

    private static let thumbnail: CGFloat = 32

    static func nsImage(bundleID: String?, executablePath: String?) -> NSImage? {
        let cacheKey = (bundleID ?? "") + "\u{1e}" + (executablePath ?? "")
        guard !cacheKey.hasPrefix("\u{1e}") || cacheKey.count > 1 else { return nil }
        if let hit = cache.object(forKey: cacheKey as NSString) {
            return hit
        }
        guard let raw = loadRaw(bundleID: bundleID, executablePath: executablePath) else {
            return nil
        }
        let small = resized(raw, to: thumbnail)
        cache.setObject(small, forKey: cacheKey as NSString, cost: Int(thumbnail * thumbnail * 4))
        return small
    }

    static func image(bundleID: String?, executablePath: String?) -> Image? {
        nsImage(bundleID: bundleID, executablePath: executablePath).map { Image(nsImage: $0) }
    }

    private static func loadRaw(bundleID: String?, executablePath: String?) -> NSImage? {
        if let path = executablePath, !path.isEmpty {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let bundleID, let url = applicationURL(for: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private static func applicationURL(for bundleID: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if bundleID.hasSuffix(".helper") {
            let parent = String(bundleID.dropLast(".helper".count))
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: parent)
        }
        return nil
    }

    private static func resized(_ image: NSImage, to side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }
}

struct AppIconView: View {
    var bundleID: String?
    var executablePath: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = AppIcon.image(bundleID: bundleID, executablePath: executablePath) {
                image
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size < 20 ? 3 : 5, style: .continuous))
    }
}
