import Foundation

struct MusicEffect: Codable, Equatable {
    var dynamicColors = false
    var color = RGBColor(r: 0.18, g: 0.64, b: 1)
    var bassColor = RGBColor(r: 1, g: 0.03, b: 0.12)
    var midColor = RGBColor(r: 0.12, g: 1, b: 0.36)
    var trebleColor = RGBColor(r: 0.18, g: 0.42, b: 1)
    var sensitivity = 1.0
    var smoothing = 0.3
    var brightness = 1.0

    private enum CodingKeys: String, CodingKey {
        case dynamicColors, color, bassColor, midColor, trebleColor, sensitivity, smoothing, brightness
    }
}

extension MusicEffect {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dynamicColors = try values.decodeIfPresent(Bool.self, forKey: .dynamicColors) ?? dynamicColors
        color = try values.decodeIfPresent(RGBColor.self, forKey: .color) ?? color
        bassColor = try values.decodeIfPresent(RGBColor.self, forKey: .bassColor) ?? bassColor
        midColor = try values.decodeIfPresent(RGBColor.self, forKey: .midColor) ?? midColor
        trebleColor = try values.decodeIfPresent(RGBColor.self, forKey: .trebleColor) ?? trebleColor
        sensitivity = try values.decodeIfPresent(Double.self, forKey: .sensitivity) ?? sensitivity
        smoothing = try values.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        brightness = try values.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
    }
}

typealias MusicBands = SIMD3<Float>

struct StereoMusicLevels {
    var left: MusicBands
    var right: MusicBands

    static let zero = Self(mono: .zero)

    init(left: MusicBands, right: MusicBands) {
        self.left = left
        self.right = right
    }

    init(mono: MusicBands) { self.init(left: mono, right: mono) }

    var combined: MusicBands {
        let power = (left * left + right * right) * 0.5
        return MusicBands(sqrt(power.x), sqrt(power.y), sqrt(power.z))
    }
}

struct MusicSpectrum {
    private var bass: Biquad
    private var midLow: Biquad
    private var midHigh: Biquad
    private var treble: Biquad
    private var energy: MusicBands = .zero
    private var count = 0
    private let windowSize: Int

    init(sampleRate: Double) {
        windowSize = max(1, Int(sampleRate * 0.01))
        bass = Biquad(cutoff: 180, sampleRate: sampleRate, highPass: false)
        midLow = Biquad(cutoff: 180, sampleRate: sampleRate, highPass: true)
        midHigh = Biquad(cutoff: 2_200, sampleRate: sampleRate, highPass: false)
        treble = Biquad(cutoff: 2_200, sampleRate: sampleRate, highPass: true)
    }

    mutating func consume(_ samples: UnsafeBufferPointer<Float>, spacing: Int = 1) -> MusicBands? {
        var latest: MusicBands?
        for index in stride(from: 0, to: samples.count, by: spacing) {
            let sample = samples[index]
            let input = sample.isFinite ? sample : 0
            let bands = MusicBands(bass.filter(input), midHigh.filter(midLow.filter(input)), treble.filter(input))
            energy += bands * bands
            count += 1
            if count == windowSize {
                let mean = energy / Float(windowSize)
                latest = MusicBands(sqrt(mean.x), sqrt(mean.y), sqrt(mean.z))
                count = 0
                energy = .zero
            }
        }
        return latest
    }
}

struct StereoMusicSpectrum {
    private var left: MusicSpectrum
    private var right: MusicSpectrum

    init(sampleRate: Double) {
        left = MusicSpectrum(sampleRate: sampleRate)
        right = MusicSpectrum(sampleRate: sampleRate)
    }

    mutating func consume(left l: UnsafeBufferPointer<Float>, right r: UnsafeBufferPointer<Float>) -> StereoMusicLevels? {
        let count = min(l.count, r.count)
        let leftLevels = left.consume(UnsafeBufferPointer(start: l.baseAddress, count: count))
        let rightLevels = right.consume(UnsafeBufferPointer(start: r.baseAddress, count: count))
        return pair(leftLevels, rightLevels)
    }

    mutating func consumeInterleaved(_ samples: UnsafeBufferPointer<Float>) -> StereoMusicLevels? {
        let count = samples.count - samples.count % 2
        guard count > 0, let base = samples.baseAddress else { return nil }
        let leftLevels = left.consume(UnsafeBufferPointer(start: base, count: count), spacing: 2)
        let rightLevels = right.consume(UnsafeBufferPointer(start: base + 1, count: count - 1), spacing: 2)
        return pair(leftLevels, rightLevels)
    }

    private func pair(_ left: MusicBands?, _ right: MusicBands?) -> StereoMusicLevels? {
        guard let left, let right else { return nil }
        return StereoMusicLevels(left: left, right: right)
    }
}

private struct Biquad {
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    init(cutoff: Double, sampleRate: Double, highPass: Bool) {
        let omega = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let c = cos(omega), alpha = sin(omega) / sqrt(2)
        let scale = 1 / (1 + alpha)
        let edge = (highPass ? 1 + c : 1 - c) / 2
        b0 = Float(edge * scale)
        b1 = Float((highPass ? -2 : 2) * edge * scale)
        b2 = b0
        a1 = Float(-2 * c * scale)
        a2 = Float((1 - alpha) * scale)
    }

    mutating func filter(_ sample: Float) -> Float {
        let out = b0 * sample + z1
        z1 = b1 * sample - a1 * out + z2
        z2 = b2 * sample - a2 * out
        return out
    }
}

final class MusicRenderer {
    private var effect: MusicEffect
    private let lamps: [(pan: Float, height: Double)]
    private var palette: [RGBColor] = []
    private var envelope: MusicBands = .zero
    private var leftEnvelope: MusicBands = .zero
    private var rightEnvelope: MusicBands = .zero
    private var leftKick = KickWave()
    private var rightKick = KickWave()

    init(effect: MusicEffect, positions: [GradientPoint]) {
        self.effect = effect
        let hasHeight = positions.contains { $0.y != 0.5 }
        lamps = positions.map {
            (pan: Float($0.x), height: hasHeight ? 1 - $0.y : 0)
        }
        update(effect: effect)
    }

    func update(effect: MusicEffect) {
        if self.effect.dynamicColors != effect.dynamicColors {
            if effect.dynamicColors {
                leftEnvelope = envelope
                rightEnvelope = envelope
                leftKick = KickWave()
                rightKick = KickWave()
            } else {
                envelope = (leftEnvelope + rightEnvelope) * 0.5
            }
        }
        self.effect = effect
        palette = [effect.bassColor, effect.midColor, effect.trebleColor].map { $0.clamped() }
    }

    func frame(levels: StereoMusicLevels, elapsed: Double) -> [RGBColor] {
        let smoothing = min(0.9, max(0, effect.smoothing))
        let time = max(0, elapsed)
        let attack = smoothing > 0 ? Float(exp(-time / (0.06 * smoothing * smoothing))) : 0
        let release = smoothing > 0 ? Float(exp(-time / (0.15 * smoothing + 0.9 * smoothing * smoothing))) : 0
        let sensitivity = Float(min(3, max(0.25, effect.sensitivity)))
        let brightness = min(1, max(0, effect.brightness))
        if effect.dynamicColors {
            let left = voiceLevels(levels.left, sensitivity: sensitivity)
            let right = voiceLevels(levels.right, sensitivity: sensitivity)
            let releases = MusicBands(release, release, release * release)
            leftEnvelope = smooth(leftEnvelope, toward: left, attack: attack, release: releases)
            rightEnvelope = smooth(rightEnvelope, toward: right, attack: attack, release: releases)
            leftKick.advance(with: Double(left.x), elapsed: time)
            rightKick.advance(with: Double(right.x), elapsed: time)
            return dynamicFrame(brightness: brightness)
        }

        let target = displayLevels(levels.combined, sensitivity: sensitivity)
        envelope = smooth(envelope, toward: target, attack: attack, release: MusicBands(repeating: release))
        let level = Double(max(envelope.x, max(envelope.y, envelope.z)))
        let color = effect.color.clamped()
        let feather = 0.25
        // One level across the whole monitor; physical height alone sets the fill.
        return lamps.map { lamp in
            let fill = min(1, max(0, (level - lamp.height * (1 - feather)) / feather))
            return color.scaled(by: brightness * level * fill)
        }
    }

    private func displayLevels(_ signal: MusicBands, sensitivity: Float) -> MusicBands {
        var result = MusicBands.zero
        for index in 0..<3 {
            let db = 20 * log10(max(0.000001, signal[index] * sensitivity))
            result[index] = pow(min(1, max(0, (db + 56) / 45)), 1.65)
        }
        return result
    }

    private func voiceLevels(_ signal: MusicBands, sensitivity: Float) -> MusicBands {
        let peak = max(signal.x, max(signal.y, signal.z))
        guard peak > 0 else { return .zero }
        let levels = displayLevels(signal, sensitivity: sensitivity)
        // Suppress filter bleed so a loud kick does not light the treble layer.
        let presence = signal / peak
        return MusicBands(levels.x * Float(softEdge(Double(presence.x), from: 0.09, to: 0.34)),
                          levels.y * Float(softEdge(Double(presence.y), from: 0.09, to: 0.34)),
                          levels.z * Float(softEdge(Double(presence.z), from: 0.09, to: 0.34)))
    }

    private func smooth(_ previous: MusicBands, toward target: MusicBands, attack: Float, release: MusicBands) -> MusicBands {
        var result = MusicBands.zero
        for index in 0..<3 {
            let keep = target[index] > previous[index] ? attack : release[index]
            let next = target[index] + (previous[index] - target[index]) * keep
            result[index] = next > 0.004 ? next : 0
        }
        return result
    }

    private func dynamicFrame(brightness: Double) -> [RGBColor] {
        lamps.map { lamp in
            let pan = lamp.pan
            let blend = 0.08 + 0.84 * pan
            let local = leftEnvelope + (rightEnvelope - leftEnvelope) * blend
            let bass = Double(local.x), mids = Double(local.y), treble = Double(local.z)
            let height = lamp.height
            let edge = Double(abs(2 * pan - 1))
            let leftTrail = leftKick.energy(at: height)
            let kick = leftTrail + (rightKick.energy(at: height) - leftTrail) * Double(blend)

            let bassReach = 0.22 + 0.65 * bass
            let lowLight = min(1, (bass * (1 - softEdge(height, from: bassReach - 0.24, to: bassReach)) + kick)
                               * (0.62 + 0.38 * edge))
            let midSpread = 0.22 + 0.26 * mids
            let midLight = mids * (1 - softEdge(abs(height - 0.49), from: midSpread * 0.25, to: midSpread))
                * (0.55 + 0.45 * edge)
            let highLight = treble * softEdge(height, from: 0.68 - 0.16 * treble, to: 0.97)

            let peak = max(lowLight, max(midLight, highLight))
            guard peak > 0 else { return .black }
            let sum = lowLight + midLight + highLight
            let weight = lowLight * lowLight + midLight * midLight + highLight * highLight
            let gain = brightness * min(1, peak + 0.26 * (sum - peak)) / weight
            let a = palette[0].scaled(by: lowLight * lowLight * gain)
            let b = palette[1].scaled(by: midLight * midLight * gain)
            let c = palette[2].scaled(by: highLight * highLight * gain)
            return RGBColor(r: a.r + b.r + c.r, g: a.g + b.g + c.g, b: a.b + b.b + c.b)
        }
    }
}

private func softEdge(_ value: Double, from low: Double, to high: Double) -> Double {
    let t = min(1, max(0, (value - low) / (high - low)))
    return t * t * (3 - 2 * t)
}

private struct KickWave {
    private var baseline = 0.0
    private var previous = 0.0
    private var age = 1.0
    private var strength = 0.0
    private let duration = 0.36

    mutating func advance(with bass: Double, elapsed: Double) {
        age = min(duration + 1, age + elapsed)
        let onset = bass - baseline
        if bass > 0.37, onset > 0.18, bass - previous > 0.045, age >= 0.14 {
            age = 0
            strength = min(0.65, onset)
        }
        baseline = bass + (baseline - bass) * exp(-elapsed / 0.19)
        previous = bass
    }

    func energy(at height: Double) -> Double {
        guard age < duration else { return 0 }
        let progress = age / duration
        let travel = 1 - softEdge(abs(height - progress * 0.9), from: 0.06, to: 0.25)
        return strength * (1 - progress) * travel
    }
}
