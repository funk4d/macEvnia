import AppKit

enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    private static var images: [String: NSImage] = [:]

    static func image(resource: String, source: NSImage, hasUpdate: Bool) -> NSImage {
        if let image = images[resource] { return image }
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            if hasUpdate {
                // Keep the Sketch badge separate so AppKit tints only the monochrome artwork.
                NSGraphicsContext.current?.cgContext.clear(Self.badgeRect(in: rect))
            }
            return true
        }
        image.isTemplate = true
        images[resource] = image
        return image
    }

    static func badgeRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.75,
               width: rect.width * 0.25, height: rect.height * 0.25)
    }
}

final class MenuBarUpdateBadgeView: NSView {
    var sourceImage: NSImage? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let button = superview as? NSStatusBarButton, let cell = button.cell as? NSButtonCell,
              let sourceImage else { return }
        sourceImage.draw(in: MenuBarIcon.badgeRect(in: cell.imageRect(forBounds: button.bounds)),
                         from: MenuBarIcon.badgeRect(in: NSRect(origin: .zero, size: sourceImage.size)),
                         operation: .sourceOver, fraction: 1)
    }
}
