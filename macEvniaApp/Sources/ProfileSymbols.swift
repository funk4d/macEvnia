import AppKit

enum ProfileSymbols {
    private static var centeredImages: [String: NSImage] = [:]

    struct Choice {
        let name: String
        let title: String
    }

    static let choices: [Choice] = [
        Choice(name: "display", title: "Display"),
        Choice(name: "desktopcomputer", title: "Desktop"),
        Choice(name: "laptopcomputer", title: "Laptop"),
        Choice(name: "tv", title: "TV"),
        Choice(name: "leaf.fill", title: "Leaf"),
        Choice(name: "battery.100", title: "Battery"),
        Choice(name: "moon.fill", title: "Moon"),
        Choice(name: "sun.max.fill", title: "Sun"),
        Choice(name: "sunset.fill", title: "Sunset"),
        Choice(name: "film.fill", title: "Movie"),
        Choice(name: "play.tv", title: "Video"),
        Choice(name: "gamecontroller.fill", title: "Gaming"),
        Choice(name: "headphones", title: "Headphones"),
        Choice(name: "music.note", title: "Music"),
        Choice(name: "paintpalette.fill", title: "Palette"),
        Choice(name: "rainbow", title: "Rainbow"),
        Choice(name: "lightbulb.fill", title: "Light Bulb"),
        Choice(name: "sparkles", title: "Sparkles"),
        Choice(name: "bolt.fill", title: "Lightning"),
        Choice(name: "flame.fill", title: "Flame"),
        Choice(name: "snowflake", title: "Snowflake"),
        Choice(name: "drop.fill", title: "Drop"),
        Choice(name: "cloud.fill", title: "Cloud"),
        Choice(name: "mountain.2.fill", title: "Mountains"),
        Choice(name: "globe", title: "Globe"),
        Choice(name: "house.fill", title: "Home"),
        Choice(name: "briefcase.fill", title: "Work"),
        Choice(name: "book.fill", title: "Reading"),
        Choice(name: "photo.fill", title: "Photo"),
        Choice(name: "camera.fill", title: "Camera"),
        Choice(name: "heart.fill", title: "Heart"),
        Choice(name: "star.fill", title: "Star"),
        Choice(name: "circle.fill", title: "Circle"),
        Choice(name: "square.fill", title: "Square"),
        Choice(name: "diamond.fill", title: "Diamond"),
        Choice(name: "power", title: "Power")
    ]

    static func image(named name: String, size: CGFloat = 16) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    static func centeredImage(named name: String) -> NSImage? {
        if let cached = centeredImages[name] { return cached }
        guard let symbol = image(named: name) else { return nil }
        let scale: CGFloat = 3
        let width = Int(ceil(symbol.size.width * scale))
        let height = Int(ceil(symbol.size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let pixels = bitmap.bitmapData else { return symbol }
        bitmap.size = symbol.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(width) / symbol.size.width, y: CGFloat(height) / symbol.size.height)
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // SF Symbols carry baseline padding; center their visible artwork, not that padded canvas.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return symbol }
        let size = NSSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale)
        let fit = min(1, 20 / max(size.width, size.height))
        let result = NSImage(cgImage: cropped, size: NSSize(width: size.width * fit, height: size.height * fit))
        result.isTemplate = true
        centeredImages[name] = result
        return result
    }
}
