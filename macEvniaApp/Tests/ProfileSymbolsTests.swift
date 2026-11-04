import AppKit
import Foundation

@main
enum ProfileSymbolsTests {
    static func main() throws {
        _ = NSApplication.shared
        var profile = AmbilightProfile.defaultProfile(name: "Saved Profile")
        let original = try JSONEncoder().encode(profile)
        var legacy = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        legacy.removeValue(forKey: "iconName")
        let decoded = try JSONDecoder().decode(AmbilightProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded == profile, "Existing profiles must retain their settings and default to Display")

        profile.iconName = "leaf.fill"
        let restored = try JSONDecoder().decode(AmbilightProfile.self, from: JSONEncoder().encode(profile))
        precondition(restored == profile, "Profile icons must survive save and reload")

        let store = ProfileStore(previewProfiles: [profile])
        let duplicate = store.addProfile(named: "Copy")
        precondition(duplicate.iconName == profile.iconName && duplicate.id != profile.id)
        store.updateSelected { $0.iconName = "moon.fill" }
        precondition(store.profiles[0].iconName == "leaf.fill")
        precondition(store.profiles[1].iconName == "moon.fill")

        let names = ProfileSymbols.choices.map(\.name) + ["record.circle", "circle.slash"]
        for name in names {
            precondition(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing SF Symbol: \(name)")
            guard let image = ProfileSymbols.centeredImage(named: name),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Missing artwork: \(name)") }
            let representation = NSBitmapImageRep(cgImage: cgImage)
            guard let pixels = representation.bitmapData else { fatalError("Missing pixel data: \(name)") }
            precondition(image.isTemplate)
            precondition(max(image.size.width, image.size.height) >= 12, "Symbol rendered too small: \(name)")
            precondition(max(image.size.width, image.size.height) <= 20.01, "Symbol exceeds its badge: \(name)")
            var minX = representation.pixelsWide, minY = representation.pixelsHigh, maxX = -1, maxY = -1
            let alpha = representation.bitmapFormat.contains(.alphaFirst) ? 0 : representation.samplesPerPixel - 1
            for y in 0..<representation.pixelsHigh {
                for x in 0..<representation.pixelsWide {
                    if pixels[y * representation.bytesPerRow + x * representation.samplesPerPixel + alpha] > 0 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            precondition(minX == 0 && minY == 0 && maxX == representation.pixelsWide - 1 && maxY == representation.pixelsHigh - 1,
                         "Visible symbol must have symmetric, zero padding: \(name)")
        }
        precondition(ProfileSymbols.centeredImage(named: "missing.symbol.for.test") != nil)
        print("PASS: legacy profile migration, icon persistence, profile isolation, \(names.count) SF Symbols and artwork centering")
    }
}
