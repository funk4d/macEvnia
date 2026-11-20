import Foundation

final class AmbilightEngine {
    enum State: Equatable {
        case stopped
        case running(UUID, String)
        case rainbow
        case solidColor
        case lightsOff
        case testingLED(Int)
        case error(String)

        var title: String {
            switch self {
            case .stopped:
                return "Stopped"
            case .running(_, let profile):
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
    private var ledTimer: DispatchSourceTimer?
    private var latestSampledColors: [RGBColor] = []
    private var rainbowTimer: DispatchSourceTimer?
    private var rainbowPhase = 0.0
    private var effectTimer: DispatchSourceTimer?
    private var musicTap: MusicAudioTap?
    private var restoreEffectFrame: (() throws -> Void)?
    private var updateEffectSettings: ((AmbilightProfile) -> Void)?
    private var pendingStaticFrame: DispatchWorkItem?
    private var stateBeforeLEDTest: State?
    private var ledTestActive = false
    private var ledTestOwnsDevice = false

    // Playback state is written on the engine queue and read by AppKit.
    private let stateLock = NSLock()
    private var _state: State = .stopped

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

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start(profile: AmbilightProfile) {
        queue.async {
            self.stopLocked(returnToAutonomous: false)
            do {
                DebugLog.write("Starting profile '\(profile.name)' mode=\(profile.mode.title)")
                if profile.mode == .followVideo {
                    try self.startScreenCaptureLocked(profile: profile)
                } else {
                    try self.startLightingEffectLocked(profile: profile)
                }
            } catch {
                DebugLog.write("Start failed: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: true)
            }
        }
    }

    func update(profile: AmbilightProfile) {
        queue.async {
            guard let previous = self.profile, previous.id == profile.id, previous.mode == profile.mode else { return }
            if profile.mode != .followVideo {
                guard self.restoreEffectFrame != nil else { return }
                self.profile = profile
                if profile.changesLighting(comparedTo: previous) {
                    self.updateEffectSettings?(profile)
                    if self.effectTimer == nil { self.scheduleStaticFrameLocked() }
                }
                self.updateRunningTitle(profile)
                return
            }
            guard self.screenStream != nil else { return }
            let oldBackend = self.backendKey(for: self.profile)
            let oldLEDRate = self.profile?.clampedLEDFPS
            var normalized = profile
            if let attributes = self.attributes {
                normalized.normalizeLEDCount(attributes.lampCount)
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
            if self.ledTimer != nil, oldLEDRate != normalized.clampedLEDFPS {
                self.scheduleLEDTimerLocked(profile: normalized)
            }
            self.updateRunningTitle(profile)
        }
    }

    private func updateRunningTitle(_ profile: AmbilightProfile) {
        let updated = State.running(profile.id, profile.name)
        if case .running = state, state != updated { state = updated }
    }

    func stop(returnToAutonomous: Bool) {
        queue.async {
            DebugLog.write("Stopping host ambilight. returnToAutonomous=\(returnToAutonomous)")
            self.stopLocked(returnToAutonomous: returnToAutonomous)
            self.state = .stopped
        }
    }

    func returnToMonitorDefaults() {
        queue.async {
            do {
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
        queue.async { [self] in
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

    func prepareForSystemPause() {
        queue.async {
            guard self.screenStream != nil || self.rainbowTimer != nil || self.effectTimer != nil else { return }
            self.stopLocked(returnToAutonomous: false)
            self.state = .stopped
        }
    }

    func setLEDTest(enabled: Bool, index: Int, profile: AmbilightProfile) {
        queue.async {
            if !enabled {
                self.stopLEDTestLocked()
                return
            }

            do {
                let ownsTemporaryDevice = self.ledTestOwnsDevice || self.device == nil
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
                if !self.ledTestActive { self.stateBeforeLEDTest = self.state }
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
        startScreenshotStreamLocked(profile: context.profile, attributes: context.attributes, lamps: context.lamps)
    }

    private func startLightingEffectLocked(profile: AmbilightProfile) throws {
        let context = try prepareHostDeviceLocked(profile: profile)
        switch profile.mode {
        case .followVideo:
            return
        case .followMusic:
            let tap = MusicAudioTap()
            try tap.start()
            musicTap = tap
            let renderer = MusicRenderer(effect: profile.music, positions: Self.positions(for: context.lamps))
            updateEffectSettings = { renderer.update(effect: $0.music) }
            var lastTime = DispatchTime.now().uptimeNanoseconds
            var lastFrame: [RGBColor]?
            restoreEffectFrame = {
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = Double(now - lastTime) / 1_000_000_000
                lastTime = now
                let colors = renderer.frame(levels: tap.latestLevels(), elapsed: elapsed)
                guard colors != lastFrame else { return }
                try context.device.setFrame(colors)
                lastFrame = colors
            }
            try restoreEffectFrame?()
            scheduleEffectTimerLocked(attributes: context.attributes)
        case .solidColor, .gradientColor:
            let positions = Self.positions(for: context.lamps)
            var settings = profile
            updateEffectSettings = { settings = $0 }
            restoreEffectFrame = {
                let colors = settings.mode == .solidColor
                    ? Array(repeating: settings.solidColor.clamped(), count: context.attributes.lampCount)
                    : settings.gradient.colors(at: positions)
                try context.device.setFrame(colors)
            }
            try restoreEffectFrame?()
        case .rainbow:
            var renderer = RainbowRenderer(profile.rainbow)
            let hasLayout = Self.hasLampLayout(context.lamps)
            let offsets = Self.positions(for: context.lamps).enumerated().map { index, position in
                let fraction = Double(index) / Double(max(1, context.lamps.count))
                return hasLayout ? renderer.effect.animation.offset(for: position, fallback: fraction) : fraction
            }
            var start = DispatchTime.now().uptimeNanoseconds
            var phaseOffset = 0.0
            updateEffectSettings = { profile in
                let now = DispatchTime.now().uptimeNanoseconds
                phaseOffset += Double(now - start) / 1_000_000_000 / renderer.effect.effectiveCycleSeconds
                start = now
                renderer = RainbowRenderer(profile.rainbow)
            }
            restoreEffectFrame = {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                    + phaseOffset * renderer.effect.effectiveCycleSeconds
                try context.device.setFrame(offsets.map { renderer.color(elapsedSeconds: elapsed, spatialOffset: $0) })
            }
            try restoreEffectFrame?()
            scheduleEffectTimerLocked(attributes: context.attributes)
        }
        state = .running(profile.id, profile.name)
    }

    private func scheduleEffectTimerLocked(attributes: LampArrayAttributes) {
        let hz = max(1, min(50, attributes.maxUpdateHz))
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / hz))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.renderEffectFrameLocked()
        }
        effectTimer = timer
        timer.resume()
    }

    private func scheduleStaticFrameLocked() {
        guard pendingStaticFrame == nil else { return }
        let micros = max(20_000, Int(attributes?.minUpdateIntervalMicroseconds ?? 0))
        let work = DispatchWorkItem { [weak self] in
            self?.pendingStaticFrame = nil
            self?.renderEffectFrameLocked()
        }
        pendingStaticFrame = work
        queue.asyncAfter(deadline: .now() + .microseconds(micros), execute: work)
    }

    private func renderEffectFrameLocked() {
        guard !ledTestActive else { return }
        do {
            try restoreEffectFrame?()
        } catch {
            stopLocked(returnToAutonomous: true)
            state = .error(error.localizedDescription)
        }
    }

    private static func hasLampLayout(_ lamps: [LampAttributes]) -> Bool {
        guard let first = lamps.first else { return false }
        return lamps.contains { $0.xMicrometers != first.xMicrometers || $0.yMicrometers != first.yMicrometers }
    }

    static func positions(for lamps: [LampAttributes]) -> [GradientPoint] {
        guard hasLampLayout(lamps) else {
            return lamps.indices.map { GradientPoint(x: Double($0) / Double(max(1, lamps.count - 1)), y: 0.5) }
        }
        let xs = lamps.map(\.xMicrometers), ys = lamps.map(\.yMicrometers)
        func normalize(_ values: [UInt32]) -> [Double] {
            let low = values.min() ?? 0, high = values.max() ?? 0
            return values.map { high == low ? 0.5 : Double($0 - low) / Double(high - low) }
        }
        return zip(normalize(xs), normalize(ys)).map { GradientPoint(x: $0.0, y: $0.1) }
    }

    private func prepareHostDeviceLocked(profile: AmbilightProfile) throws -> HostDeviceContext {
        let device = try LampArrayDevice()
        let attributes = try device.arrayAttributes()
        DebugLog.write("LampArray attributes: lamps=\(attributes.lampCount), maxHz=\(String(format: "%.1f", attributes.maxUpdateHz)), kind=0x\(String(attributes.kind, radix: 16))")
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
        stream.onColors = { [weak self, weak stream] colors in
            guard let self, let stream, self.screenStream === stream else { return }
            self.handleSampledColorsLocked(colors)
        }
        stream.onError = { [weak self, weak stream] error in
            self?.queue.async { [weak self, weak stream] in
                guard let self, let stream, self.screenStream === stream else { return }
                self.state = .error(error.localizedDescription)
                self.stopLocked(returnToAutonomous: true)
            }
        }
        self.screenStream = stream
        stream.start { [weak self, weak stream] result in
            self?.queue.async { [weak self, weak stream] in
                guard let self, let stream, self.screenStream === stream, let current = self.profile else { return }
                switch result {
                case .success:
                    DebugLog.write("\(backendName) started for profile '\(current.name)'")
                    self.scheduleLEDTimerLocked(profile: current)
                    let active = State.running(current.id, current.name)
                    if self.ledTestActive { self.stateBeforeLEDTest = active } else { self.state = active }
                case .failure(let error):
                    DebugLog.write("\(backendName) failed: \(error.localizedDescription)")
                    self.state = .error(error.localizedDescription)
                    self.stopLocked(returnToAutonomous: true)
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
        effectTimer?.cancel()
        effectTimer = nil
        pendingStaticFrame?.cancel()
        pendingStaticFrame = nil
        updateEffectSettings = nil
        musicTap?.stop()
        musicTap = nil
        restoreEffectFrame = nil
        ledTimer?.cancel()
        ledTimer = nil
        screenStream?.stop()
        screenStream = nil
        ledTestActive = false
        ledTestOwnsDevice = false
        stateBeforeLEDTest = nil
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
        guard !ledTestActive, let device, !lamps.isEmpty else { return }
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
        adjusted = applyColorTemperature(adjusted, temperature: profile.colorTemperature)

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
        let minimumReflectance = 0.08
        let inverseRed = 1 / max(minimumReflectance, wall.r)
        let inverseGreen = 1 / max(minimumReflectance, wall.g)
        let inverseBlue = 1 / max(minimumReflectance, wall.b)
        let strongestGain = max(inverseRed, max(inverseGreen, inverseBlue))

        return RGBColor(
            r: color.r * inverseRed / strongestGain,
            g: color.g * inverseGreen / strongestGain,
            b: color.b * inverseBlue / strongestGain
        ).clamped()
    }

    private func applyColorTemperature(_ color: RGBColor, temperature: Double) -> RGBColor {
        let value = min(1, max(-1, temperature))
        let tintStrength = 0.22
        let redGain = 1 + value * tintStrength
        let greenGain = 1.0
        let blueGain = 1 - value * tintStrength
        let strongestGain = max(redGain, max(greenGain, blueGain))

        return RGBColor(
            r: color.r * redGain / strongestGain,
            g: color.g * greenGain / strongestGain,
            b: color.b * blueGain / strongestGain
        ).clamped()
    }

    private func stopLEDTestLocked() {
        guard ledTestActive else { return }
        let previous = stateBeforeLEDTest ?? .stopped
        stateBeforeLEDTest = nil
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
        } else {
            do {
                try restoreEffectFrame?()
                state = previous
            } catch {
                stopLocked(returnToAutonomous: true)
                state = .error(error.localizedDescription)
            }
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
