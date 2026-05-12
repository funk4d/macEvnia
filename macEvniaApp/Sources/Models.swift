import AppKit
import Foundation

struct RGBColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let black = RGBColor(r: 0, g: 0, b: 0)
    static let white = RGBColor(r: 1, g: 1, b: 1)
    static let warmIdentify = RGBColor(r: 1, g: 0.55, b: 0.05)

    func clamped() -> RGBColor {
        RGBColor(r: min(1, max(0, r)), g: min(1, max(0, g)), b: min(1, max(0, b)))
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        self.r = Double(color.redComponent)
        self.g = Double(color.greenComponent)
        self.b = Double(color.blueComponent)
    }
}

struct AmbilightProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var displayID: UInt32?
    var fps: Int
    var ledFPS: Int
    var screenshotQuality: Int
    var brightness: Double
    var smoothing: Double
    var sampleRadius: Int
    var sampleStride: Int
    var captureFullScreen: Bool
    var useSCScreenshotManagerBackend: Bool
    var useRegionCaptureBackend: Bool
    var wallCompensationEnabled: Bool
    var wallColor: RGBColor
    var ledMultipliers: [Double]
    var autoStart: Bool
    var autoResumeAfterWake: Bool

    static func defaultProfile(name: String = "Default") -> AmbilightProfile {
        AmbilightProfile(
            id: UUID(),
            name: name,
            displayID: nil,
            fps: 30,
            ledFPS: 50,
            screenshotQuality: 50,
            brightness: 0.60,
            smoothing: 0.30,
            sampleRadius: 80,
            sampleStride: 3,
            captureFullScreen: true,
            useSCScreenshotManagerBackend: true,
            useRegionCaptureBackend: false,
            wallCompensationEnabled: false,
            wallColor: RGBColor(r: 1.0, g: 0.94, b: 0.78),
            ledMultipliers: Array(repeating: 1.0, count: 16),
            autoStart: false,
            autoResumeAfterWake: true
        )
    }

    mutating func normalizeLEDCount(_ count: Int) {
        if ledMultipliers.count < count {
            ledMultipliers.append(contentsOf: Array(repeating: 1.0, count: count - ledMultipliers.count))
        } else if ledMultipliers.count > count {
            ledMultipliers = Array(ledMultipliers.prefix(count))
        }
    }

    var clampedCaptureFPS: Int {
        min(50, max(1, fps))
    }

    var clampedLEDFPS: Int {
        min(50, max(1, ledFPS))
    }

    var clampedFPS: Int {
        clampedCaptureFPS
    }

    var clampedScreenshotQuality: Int {
        min(100, max(10, screenshotQuality))
    }

    var screenshotLongestSide: Int {
        max(90, Int((720.0 * Double(clampedScreenshotQuality) / 100.0).rounded()))
    }

    var effectiveSampleStride: Int {
        let multiplier = max(1, Int((100.0 / Double(clampedScreenshotQuality)).rounded()))
        return max(1, sampleStride) * multiplier
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayID
        case fps
        case ledFPS
        case screenshotQuality
        case brightness
        case smoothing
        case sampleRadius
        case sampleStride
        case captureFullScreen
        case useSCScreenshotManagerBackend
        case useRegionCaptureBackend
        case wallCompensationEnabled
        case wallColor
        case ledMultipliers
        case autoStart
        case autoResumeAfterWake
    }

    init(
        id: UUID,
        name: String,
        displayID: UInt32?,
        fps: Int,
        ledFPS: Int,
        screenshotQuality: Int,
        brightness: Double,
        smoothing: Double,
        sampleRadius: Int,
        sampleStride: Int,
        captureFullScreen: Bool,
        useSCScreenshotManagerBackend: Bool,
        useRegionCaptureBackend: Bool,
        wallCompensationEnabled: Bool,
        wallColor: RGBColor,
        ledMultipliers: [Double],
        autoStart: Bool,
        autoResumeAfterWake: Bool
    ) {
        self.id = id
        self.name = name
        self.displayID = displayID
        self.fps = min(50, max(1, fps))
        self.ledFPS = min(50, max(1, ledFPS))
        self.screenshotQuality = min(100, max(10, screenshotQuality))
        self.brightness = brightness
        self.smoothing = smoothing
        self.sampleRadius = sampleRadius
        self.sampleStride = sampleStride
        self.captureFullScreen = captureFullScreen
        self.useSCScreenshotManagerBackend = useSCScreenshotManagerBackend
        self.useRegionCaptureBackend = useRegionCaptureBackend
        self.wallCompensationEnabled = wallCompensationEnabled
        self.wallColor = wallColor
        self.ledMultipliers = ledMultipliers
        self.autoStart = autoStart
        self.autoResumeAfterWake = autoResumeAfterWake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            displayID: try container.decodeIfPresent(UInt32.self, forKey: .displayID),
            fps: try container.decodeIfPresent(Int.self, forKey: .fps) ?? 30,
            ledFPS: try container.decodeIfPresent(Int.self, forKey: .ledFPS) ?? 50,
            screenshotQuality: try container.decodeIfPresent(Int.self, forKey: .screenshotQuality) ?? 50,
            brightness: try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.60,
            smoothing: try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.30,
            sampleRadius: try container.decodeIfPresent(Int.self, forKey: .sampleRadius) ?? 80,
            sampleStride: try container.decodeIfPresent(Int.self, forKey: .sampleStride) ?? 3,
            captureFullScreen: try container.decodeIfPresent(Bool.self, forKey: .captureFullScreen) ?? true,
            useSCScreenshotManagerBackend: try container.decodeIfPresent(Bool.self, forKey: .useSCScreenshotManagerBackend) ?? true,
            useRegionCaptureBackend: try container.decodeIfPresent(Bool.self, forKey: .useRegionCaptureBackend) ?? false,
            wallCompensationEnabled: try container.decodeIfPresent(Bool.self, forKey: .wallCompensationEnabled) ?? false,
            wallColor: try container.decodeIfPresent(RGBColor.self, forKey: .wallColor) ?? RGBColor(r: 1.0, g: 0.94, b: 0.78),
            ledMultipliers: try container.decodeIfPresent([Double].self, forKey: .ledMultipliers) ?? Array(repeating: 1.0, count: 16),
            autoStart: try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false,
            autoResumeAfterWake: try container.decodeIfPresent(Bool.self, forKey: .autoResumeAfterWake) ?? true
        )
    }
}

struct ProfileFile: Codable {
    var selectedProfileID: UUID?
    var profiles: [AmbilightProfile]
}

final class ProfileStore {
    private(set) var profiles: [AmbilightProfile] = []
    var selectedProfileID: UUID?
    var onChange: (() -> Void)?

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("macEvnia", isDirectory: true)
    }

    private var fileURL: URL {
        supportDirectory.appendingPathComponent("profiles.json")
    }

    init() {
        load()
    }

    var selectedProfile: AmbilightProfile {
        get {
            if let selectedProfileID,
               let profile = profiles.first(where: { $0.id == selectedProfileID }) {
                return profile
            }
            return profiles.first ?? AmbilightProfile.defaultProfile()
        }
        set {
            if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[index] = newValue
            } else {
                profiles.append(newValue)
            }
            selectedProfileID = newValue.id
            saveAndNotify()
        }
    }

    func select(_ id: UUID) {
        selectedProfileID = id
        saveAndNotify()
    }

    @discardableResult
    func addProfile(named name: String) -> AmbilightProfile {
        var profile = AmbilightProfile.defaultProfile(name: name)
        if !profiles.isEmpty {
            profile = selectedProfile
            profile.id = UUID()
            profile.name = name
        }
        profiles.append(profile)
        selectedProfileID = profile.id
        saveAndNotify()
        return profile
    }

    func deleteSelectedProfile() {
        guard let selectedProfileID else { return }
        deleteProfile(id: selectedProfileID)
    }

    func deleteProfile(id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        saveAndNotify()
    }

    func updateSelected(_ update: (inout AmbilightProfile) -> Void) {
        var profile = selectedProfile
        update(&profile)
        selectedProfile = profile
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(ProfileFile.self, from: data)
            profiles = decoded.profiles.isEmpty ? [AmbilightProfile.defaultProfile()] : decoded.profiles
            selectedProfileID = decoded.selectedProfileID ?? profiles.first?.id
            for index in profiles.indices {
                profiles[index].useSCScreenshotManagerBackend = true
                profiles[index].useRegionCaptureBackend = false
            }
            save()
        } catch {
            profiles = [AmbilightProfile.defaultProfile()]
            selectedProfileID = profiles.first?.id
            save()
        }
    }

    func saveAndNotify() {
        save()
        onChange?()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(ProfileFile(selectedProfileID: selectedProfileID, profiles: profiles))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("macEvnia profile save failed: \(error)")
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
