import Foundation

/// The last user-selected playback state. Persists across cold launches and is
/// used by `AppDelegate` to restore the chosen mode after wake / HID re-attach.
enum PlaybackMode: Equatable {
    case capture
    case rainbow
    case solid(RGBColor)
    case lightsOff
    case stopped
}

extension PlaybackMode {
    var debugDescription: String {
        switch self {
        case .capture: return "capture"
        case .rainbow: return "rainbow"
        case .solid(let c): return "solid(r=\(String(format: "%.2f", c.r)), g=\(String(format: "%.2f", c.g)), b=\(String(format: "%.2f", c.b)))"
        case .lightsOff: return "lightsOff"
        case .stopped: return "stopped"
        }
    }
}

extension PlaybackMode: Codable {
    private enum Kind: String, Codable {
        case capture, rainbow, solid, lightsOff, stopped
    }
    private enum CodingKeys: String, CodingKey {
        case kind, color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .capture: self = .capture
        case .rainbow: self = .rainbow
        case .lightsOff: self = .lightsOff
        case .stopped: self = .stopped
        case .solid:
            let color = try c.decode(RGBColor.self, forKey: .color)
            self = .solid(color)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .capture: try c.encode(Kind.capture, forKey: .kind)
        case .rainbow: try c.encode(Kind.rainbow, forKey: .kind)
        case .lightsOff: try c.encode(Kind.lightsOff, forKey: .kind)
        case .stopped: try c.encode(Kind.stopped, forKey: .kind)
        case .solid(let color):
            try c.encode(Kind.solid, forKey: .kind)
            try c.encode(color, forKey: .color)
        }
    }
}

enum PlaybackModeStore {
    private static let key = "macevnia.playbackMode"

    static func load() -> PlaybackMode {
        guard let data = UserDefaults.standard.data(forKey: key),
              let mode = try? JSONDecoder().decode(PlaybackMode.self, from: data) else {
            return .stopped
        }
        return mode
    }

    static func save(_ mode: PlaybackMode) {
        guard let data = try? JSONEncoder().encode(mode) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
