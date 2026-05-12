import AppKit
import CoreGraphics
import Foundation

struct DisplayInfo: Equatable {
    var id: CGDirectDisplayID
    var name: String
    var frame: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
    var isBuiltin: Bool

    var pixelArea: Int {
        pixelWidth * pixelHeight
    }

    var looksLikeEvnia: Bool {
        let normalized = name.lowercased()
        return normalized.contains("evnia") || normalized.contains("philips")
    }
}

enum DisplayCatalog {
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                frame: screen.frame,
                pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    static func displayID(for profile: AmbilightProfile) -> CGDirectDisplayID? {
        let all = displays()
        if let displayID = profile.displayID, all.contains(where: { $0.id == displayID }) {
            return CGDirectDisplayID(displayID)
        }

        if let selected = profile.displayID {
            if let external = preferredExternalDisplay(in: all) {
                DebugLog.write("Stored display \(selected) is unavailable; using external display \(external.name) \(external.pixelWidth)x\(external.pixelHeight)")
                return external.id
            }
            DebugLog.write("Stored display \(selected) is unavailable and no external display is online yet")
            return nil
        }

        return preferredExternalDisplay(in: all)?.id ?? all.first?.id
    }

    static func preferredExternalDisplay(in displays: [DisplayInfo]? = nil) -> DisplayInfo? {
        let all = displays ?? self.displays()
        let external = all.filter { !$0.isBuiltin }
        return external.first(where: { $0.looksLikeEvnia })
            ?? external.max(by: { $0.pixelArea < $1.pixelArea })
    }

    static func summary() -> String {
        let all = displays()
        if all.isEmpty {
            return "none"
        }
        return all.map { display in
            let kind = display.isBuiltin ? "builtin" : "external"
            return "\(display.name)#\(display.id) \(display.pixelWidth)x\(display.pixelHeight) \(kind)"
        }.joined(separator: "; ")
    }
}
