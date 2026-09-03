import Foundation

final class AmbilightEngine {
    enum State: Equatable {
        case stopped
        case running(String)
        case rainbow
        case solidColor
        case lightsOff
        case testingLED(Int)
        case error(String)

        var title: String {
            switch self {
            case .stopped:
                return "Stopped"
            case .running(let profile):
                return "Running: \(profile)"
            case .rainbow:
                return "Rainbow"
            case .solidColor:
                return "Solid Color"
            case .lightsOff:
                return "Lights Off"
            case .testingLED(let index):
                return "Testing LED \(index)"
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }

    private let queue = DispatchQueue(label: "macEvnia.engine", qos: .utility)
    private var screenStream: ScreenColorStream?
    private var device: LampArrayDevice?
    private var attributes: LampArrayAttributes?
    private var lamps: [LampAttributes] = []
    private var previousColors: [RGBColor?] = []
    private var profile: AmbilightProfile?
    private var shouldResumeScreenCapture = false {
        didSet {
            wantsScreenCaptureResume = shouldResumeScreenCapture
        }
    }
    private var resumeProfile: AmbilightProfile?
    private var ledTimer: DispatchSourceTimer?
    private var latestSampledColors: [RGBColor] = []
    private var rainbowTimer: DispatchSourceTimer?
    private var rainbowPhase = 0.0
    private var ledTestActive = false
    private var ledTestOwnsDevice = false

    /// `state` and `wantsScreenCaptureResume` are written on `queue` but read
    /// from the main thread (menu rebuild, wake/resume checks), so both need a
    /// lock. `State` carries `String` payloads, so an unsynchronised read can
    /// tear across the payload words rather than merely returning a stale value.
    private let stateLock = NSLock()
    private var _state: State = .stopped
    private var _wantsScreenCaptureResume = false

    private(set) var state: State {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _state
        }
        set {
            stateLock.lock()
            _state = newValue
            stateLock.unlock()
            DebugLog.write("State changed: \(newValue.title)")
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(newValue)
            }
        }
    }

    var onStateChange: ((State) -> Void)?

    private(set) var wantsScreenCaptureResume: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _wantsScreenCaptureResume
        }
        set {
            stateLock.lock()
            _wantsScreenCaptureResume = newValue
            stateLock.unlock()
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start(profile: AmbilightProfile) {
        queue.async {
            self.shouldResumeScreenCapture = true
            self.resumeProfile = profile
            self.stopLocked(returnToAutonomous: false)
            do {
                DebugLog.write("Starting profile '\(profile.name)' capture=\(profile.clampedCaptureFPS) FPS led=\(profile.clampedLEDFPS) Hz")
                try self.startScreenCaptureLocked(profile: profile)
            } catch {
                DebugLog.write("Start failed: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: false)
            }
        }
    }

    func update(profile: AmbilightProfile) {
        queue.async {
            let oldBackend = self.backendKey(for: self.profile)
            var normalized = profile
            if let attributes = self.attributes {
                normalized.normalizeLEDCount(attributes.lampCount)
            }
            if self.shouldResumeScreenCapture {
                self.resumeProfile = normalized
            }
            self.profile = normalized

            if self.screenStream != nil, oldBackend != self.backendKey(for: normalized) {
                DebugLog.write("Switching capture backend")
                self.stopLocked(returnToAutonomous: false)
                do {
                    try self.startScreenCaptureLocked(profile: normalized)
                } catch {
                    self.state = .error(error.localizedDescription)
                    self.stopLocked(returnToAutonomous: false)
                }
                return
            }

            self.screenStream?.update(profile: normalized)
            if self.ledTimer != nil {
                self.scheduleLEDTimerLocked(profile: normalized)
            }
        }
    }

    func stop(returnToAutonomous: Bool) {
        queue.async {
            self.shouldResumeScreenCapture = false
            self.resumeProfile = nil
            DebugLog.write("Stopping host ambilight. returnToAutonomous=\(returnToAutonomous)")
            self.stopLocked(returnToAutonomous: returnToAutonomous)
            self.state = .stopped
        }
    }

    func returnToMonitorDefaults() {
        queue.async {
            do {
                self.shouldResumeScreenCapture = false
                self.resumeProfile = nil
                let device: LampArrayDevice
                if let current = self.device {
                    device = current
                } else {
                    device = try LampArrayDevice()
                }
                try device.setAutonomous(true)
                self.stopLocked(returnToAutonomous: false)
                self.state = .stopped
            } catch {
                self.state = .error(error.localizedDescription)
            }
        }
    }

    func startRainbow(profile: AmbilightProfile) {
        queue.async {
            self.shouldResumeScreenCapture = false
            self.resumeProfile = nil
            self.stopLocked(returnToAutonomous: false)
            do {
                let context = try self.prepareHostDeviceLocked(profile: profile)
                self.rainbowPhase = 0
                self.state = .rainbow
                self.sendRainbowFrameLocked(profile: context.profile)

                let fps = max(1, min(50, context.profile.clampedLEDFPS))
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(max(20, 1_000 / fps)))
                timer.setEventHandler { [weak self] in
                    self?.sendRainbowFrameLocked(profile: context.profile)
                }
                self.rainbowTimer = timer
                timer.resume()
            } catch {
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: false)
            }
        }
    }

    func setSolidColor(_ color: RGBColor, profile: AmbilightProfile) {
        queue.async {
            do {
                self.shouldResumeScreenCapture = false
                self.resumeProfile = nil
                if case .solidColor = self.state, let attributes = self.attributes, self.device != nil {
                    var normalized = profile
                    normalized.normalizeLEDCount(attributes.lampCount)
                    self.profile = normalized
                    try self.sendSolidFrameLocked(color: color, profile: normalized)
                } else {
                    self.stopLocked(returnToAutonomous: false)
                    let context = try self.prepareHostDeviceLocked(profile: profile)
                    try self.sendSolidFrameLocked(color: color, profile: context.profile)
                }
                self.state = .solidColor
            } catch {
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: false)
            }
        }
    }

    func turnLightsOff(profile: AmbilightProfile) {
        queue.async {
            self.shouldResumeScreenCapture = false
            self.resumeProfile = nil
            self.stopLocked(returnToAutonomous: false)
            do {
                let context = try self.prepareHostDeviceLocked(profile: profile)
                try context.device.setFrame(Array(repeating: .black, count: context.attributes.lampCount))
                self.state = .lightsOff
            } catch {
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: false)
            }
        }
    }

    func resumeAfterSystemWake(profile: AmbilightProfile, forceRestart: Bool = false) {
        queue.async {
            guard self.shouldResumeScreenCapture else { return }
            var profileToResume = profile
            if let stored = self.resumeProfile, stored.id == profile.id {
                profileToResume = stored
            }
            guard profileToResume.autoResumeAfterWake else { return }
            if self.screenStream != nil, case .running = self.state, !forceRestart {
                return
            }

            self.resumeProfile = profileToResume
            DebugLog.write("Resuming host ambilight. forceRestart=\(forceRestart)")
            self.stopLocked(returnToAutonomous: false)
            self.state = .stopped
            do {
                try self.startScreenCaptureLocked(profile: profileToResume)
            } catch {
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: false)
            }
        }
    }

    func prepareForSystemPause(profile: AmbilightProfile) {
        queue.async {
            guard self.shouldResumeScreenCapture || self.screenStream != nil else { return }
            var profileToResume = self.profile ?? profile
            profileToResume.autoResumeAfterWake = profile.autoResumeAfterWake
            guard profileToResume.autoResumeAfterWake else { return }

            self.shouldResumeScreenCapture = true
            self.resumeProfile = profileToResume
            if self.screenStream != nil {
                self.stopLocked(returnToAutonomous: false)
                self.state = .stopped
            }
        }
    }

    func setLEDTest(enabled: Bool, index: Int, profile: AmbilightProfile) {
        queue.async {
            if !enabled {
                self.stopLEDTestLocked()
                return
            }

            do {
                let ownsTemporaryDevice = self.device == nil
                let device: LampArrayDevice
                if let current = self.device {
                    device = current
                } else {
                    device = try LampArrayDevice()
                }

                let attributes: LampArrayAttributes
                if let current = self.attributes {
                    attributes = current
                } else {
                    attributes = try device.arrayAttributes()
                }

                if self.lamps.isEmpty {
                    self.lamps = try device.lampAttributes(count: attributes.lampCount)
                }
                try device.setAutonomous(false)
                let count = attributes.lampCount
                var colors = Array(repeating: RGBColor.black, count: count)
                if index >= 0 && index < count {
                    let multiplier = index < profile.ledMultipliers.count ? profile.ledMultipliers[index] : 1.0
                    colors[index] = RGBColor(
                        r: RGBColor.warmIdentify.r * min(2.0, max(0, multiplier)),
                        g: RGBColor.warmIdentify.g * min(2.0, max(0, multiplier)),
                        b: RGBColor.warmIdentify.b * min(2.0, max(0, multiplier))
                    ).clamped()
                }
                try device.setFrame(colors)
                self.ledTestActive = true
                self.ledTestOwnsDevice = ownsTemporaryDevice
                self.state = .testingLED(index)
                if ownsTemporaryDevice {
                    self.device = device
                    self.attributes = attributes
                }
            } catch {
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func startScreenCaptureLocked(profile: AmbilightProfile) throws {
        let context = try prepareHostDeviceLocked(profile: profile)
        resumeProfile = context.profile
        startScreenshotStreamLocked(profile: context.profile, attributes: context.attributes, lamps: context.lamps)
    }

    private func prepareHostDeviceLocked(profile: AmbilightProfile) throws -> HostDeviceContext {
        let device = try LampArrayDevice()
        let attributes = try device.arrayAttributes()
        let lamps = try device.lampAttributes(count: attributes.lampCount)
        try device.setAutonomous(false)

        var normalized = profile
        normalized.normalizeLEDCount(attributes.lampCount)
        self.device = device
        self.attributes = attributes
        self.lamps = lamps
        self.previousColors = Array(repeating: nil, count: attributes.lampCount)
        self.latestSampledColors = []
        self.profile = normalized
        return HostDeviceContext(device: device, attributes: attributes, lamps: lamps, profile: normalized)
    }

    private func startScreenshotStreamLocked(
        profile: AmbilightProfile,
        attributes: LampArrayAttributes,
        lamps: [LampAttributes]
    ) {
        screenStream?.stop()
        let stream: ScreenColorStream
        if profile.useRegionCaptureBackend {
            stream = RegionCaptureAmbilightStream(
                profile: profile,
                attributes: attributes,
                lamps: lamps,
                outputQueue: queue
            )
        } else if profile.useSCScreenshotManagerBackend {
            stream = SCScreenshotAmbilightStream(
                profile: profile,
                attributes: attributes,
                lamps: lamps,
                outputQueue: queue
            )
        } else {
            stream = ScreenshotAmbilightStream(
                profile: profile,
                attributes: attributes,
                lamps: lamps,
                outputQueue: queue
            )
        }
        let backendName = backendName(for: profile)
        stream.onColors = { [weak self] colors in
            self?.handleSampledColorsLocked(colors)
        }
        stream.onError = { [weak self] error in
            self?.queue.async {
                self?.state = .error(error.localizedDescription)
                self?.stopLocked(returnToAutonomous: true)
            }
        }
        self.screenStream = stream
        stream.start { [weak self] result in
            self?.queue.async {
                switch result {
                case .success:
                    if self?.device != nil {
                        DebugLog.write("\(backendName) started for profile '\(profile.name)'")
                        self?.scheduleLEDTimerLocked(profile: profile)
                        self?.state = .running(profile.name)
                    }
                case .failure(let error):
                    DebugLog.write("\(backendName) failed: \(error.localizedDescription)")
                    self?.state = .error(error.localizedDescription)
                    self?.stopLocked(returnToAutonomous: true)
                }
            }
        }
    }

    private func backendKey(for profile: AmbilightProfile?) -> String {
        guard let profile else { return "none" }
        if profile.useRegionCaptureBackend { return "region" }
        if profile.useSCScreenshotManagerBackend { return "scscreenshot" }
        return "mss"
    }

    private func backendName(for profile: AmbilightProfile) -> String {
        if profile.useRegionCaptureBackend { return "tiny region capture backend" }
        if profile.useSCScreenshotManagerBackend { return "SCScreenshotManager frame backend" }
        return "MSS-style CoreGraphics screenshot backend"
    }

    private func stopLocked(returnToAutonomous: Bool) {
        rainbowTimer?.cancel()
        rainbowTimer = nil
        ledTimer?.cancel()
        ledTimer = nil
        screenStream?.stop()
        screenStream = nil
        ledTestActive = false
        ledTestOwnsDevice = false
        if returnToAutonomous {
            try? device?.setAutonomous(true)
        }
        device = nil
        attributes = nil
        lamps = []
        previousColors = []
        latestSampledColors = []
        profile = nil
    }

    private func sendRainbowFrameLocked(profile: AmbilightProfile) {
        guard let device, !lamps.isEmpty else { return }
        let cycleSeconds = 5.0
        rainbowPhase += 1.0 / (Double(max(1, profile.clampedLEDFPS)) * cycleSeconds)
        if rainbowPhase > 1 {
            rainbowPhase -= 1
        }
        let count = max(1, lamps.count)
        let colors = (0..<count).map { index in
            let hue = rainbowPhase + Double(index) / Double(count)
            return outputColor(hsvToRGB(hue: hue, saturation: 1, value: 1), ledIndex: index, profile: profile)
        }

        do {
            try device.setFrame(colors)
        } catch {
            state = .error(error.localizedDescription)
            stopLocked(returnToAutonomous: true)
        }
    }

    private func sendSolidFrameLocked(color: RGBColor, profile: AmbilightProfile) throws {
        guard let device, let attributes else { return }
        let colors = (0..<attributes.lampCount).map { index in
            outputColor(color, ledIndex: index, profile: profile)
        }
        try device.setFrame(colors)
    }

    private func handleSampledColorsLocked(_ sampled: [RGBColor]) {
        if ledTestActive {
            return
        }
        latestSampledColors = sampled
    }

    private func scheduleLEDTimerLocked(profile: AmbilightProfile) {
        ledTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalNanoseconds = UInt64(max(1.0 / Double(max(1, profile.clampedLEDFPS)), 0.02) * 1_000_000_000)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNanoseconds)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.sendLatestAmbilightFrameLocked()
        }
        ledTimer = timer
        timer.resume()
    }

    private func sendLatestAmbilightFrameLocked() {
        if ledTestActive {
            return
        }
        guard let device, let profile else { return }
        guard !latestSampledColors.isEmpty else { return }

        let colors = latestSampledColors.enumerated().map { index, color in
            transform(color: color, ledIndex: index, profile: profile)
        }

        do {
            try device.setFrame(colors)
        } catch {
            state = .error(error.localizedDescription)
            stopLocked(returnToAutonomous: true)
        }
    }

    private func outputColor(_ color: RGBColor, ledIndex: Int, profile: AmbilightProfile) -> RGBColor {
        let ledMultiplier = ledIndex < profile.ledMultipliers.count ? profile.ledMultipliers[ledIndex] : 1.0
        let gain = max(0, profile.brightness) * max(0, ledMultiplier)
        return RGBColor(r: color.r * gain, g: color.g * gain, b: color.b * gain).clamped()
    }

    private func transform(color: RGBColor, ledIndex: Int, profile: AmbilightProfile) -> RGBColor {
        var adjusted = color

        if profile.wallCompensationEnabled {
            adjusted = compensate(color: adjusted, wall: profile.wallColor)
        }

        if previousColors.count != lamps.count {
            previousColors = Array(repeating: nil, count: lamps.count)
        }

        if let previous = previousColors[safe: ledIndex] ?? nil {
            let keep = smoothingKeepFactor(profile: profile)
            adjusted = RGBColor(
                r: previous.r * keep + adjusted.r * (1 - keep),
                g: previous.g * keep + adjusted.g * (1 - keep),
                b: previous.b * keep + adjusted.b * (1 - keep)
            )
        }
        if ledIndex < previousColors.count {
            previousColors[ledIndex] = adjusted
        }

        return outputColor(adjusted, ledIndex: ledIndex, profile: profile)
    }

    private func smoothingKeepFactor(profile: AmbilightProfile) -> Double {
        let smoothing = min(0.95, max(0, profile.smoothing))
        guard smoothing > 0 else { return 0 }

        let ledHz = Double(max(1, profile.clampedLEDFPS))
        let settleSeconds = 0.08 + smoothing * smoothing * 1.75
        let framesToSettle = max(1, settleSeconds * ledHz)
        return pow(0.05, 1.0 / framesToSettle)
    }

    private func compensate(color: RGBColor, wall: RGBColor) -> RGBColor {
        let wall = wall.clamped()
        let average = max(0.05, (wall.r + wall.g + wall.b) / 3.0)
        let strength = 0.75

        func channel(_ value: Double, wallChannel: Double) -> Double {
            let gain = min(2.5, max(0.35, average / max(0.12, wallChannel)))
            return value * (1 + (gain - 1) * strength)
        }

        return RGBColor(
            r: channel(color.r, wallChannel: wall.r),
            g: channel(color.g, wallChannel: wall.g),
            b: channel(color.b, wallChannel: wall.b)
        ).clamped()
    }

    private func stopLEDTestLocked() {
        guard ledTestActive else { return }
        ledTestActive = false
        if ledTestOwnsDevice {
            try? device?.setAutonomous(true)
            ledTestOwnsDevice = false
            device = nil
            attributes = nil
            lamps = []
            previousColors = []
            profile = nil
            state = .stopped
        } else if let profile {
            state = .running(profile.name)
        } else {
            state = .stopped
        }
    }
}

private struct HostDeviceContext {
    var device: LampArrayDevice
    var attributes: LampArrayAttributes
    var lamps: [LampAttributes]
    var profile: AmbilightProfile
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func hsvToRGB(hue: Double, saturation: Double, value: Double) -> RGBColor {
    let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let i = floor(h)
    let f = h - i
    let p = value * (1 - saturation)
    let q = value * (1 - saturation * f)
    let t = value * (1 - saturation * (1 - f))

    switch Int(i) % 6 {
    case 0:
        return RGBColor(r: value, g: t, b: p)
    case 1:
        return RGBColor(r: q, g: value, b: p)
    case 2:
        return RGBColor(r: p, g: value, b: t)
    case 3:
        return RGBColor(r: p, g: q, b: value)
    case 4:
        return RGBColor(r: t, g: p, b: value)
    default:
        return RGBColor(r: value, g: p, b: q)
    }
}
