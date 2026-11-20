import Foundation

enum ProfileMode: String, Codable, CaseIterable {
    case followVideo, followMusic, solidColor, gradientColor, rainbow

    var title: String {
        switch self {
        case .followVideo: return "Follow Video"
        case .followMusic: return "Follow Music"
        case .solidColor: return "Solid Color"
        case .gradientColor: return "Gradient Color"
        case .rainbow: return "Animation"
        }
    }
}

enum ProfileIconStyle: String, Codable, CaseIterable {
    case symbol, color, gradient
}

enum ProfileArtwork: Equatable {
    case symbol(String)
    case color(RGBColor)
    case gradient(GradientEffect)
}

struct GradientPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct GradientEffect: Codable, Equatable {
    var startColor = RGBColor(r: 0.15, g: 0.45, b: 1)
    var endColor = RGBColor(r: 1, g: 0.32, b: 0.5)
    var start = GradientPoint(x: 0.12, y: 0.68)
    var end = GradientPoint(x: 0.88, y: 0.32)

    func colors(at positions: [GradientPoint]) -> [RGBColor] {
        let curve = OKLCHTransition(from: startColor, to: endColor)
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        return positions.map { point in
            let t = lengthSquared > 0.000001
                ? ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
                : 0.5
            return curve.color(at: t)
        }
    }
}

enum RainbowAnimation: String, Codable, CaseIterable {
    case wave, reverseWave, cycle, pulse

    var title: String {
        switch self {
        case .wave: return "Wave"
        case .reverseWave: return "Reverse Wave"
        case .cycle: return "Color Cycle"
        case .pulse: return "Pulse"
        }
    }

    func offset(for position: GradientPoint, fallback: Double) -> Double {
        let x = position.x - 0.5, y = position.y - 0.5
        return hypot(x, y) > 0.001 ? atan2(y, x) / (2 * .pi) : fallback
    }
}

struct RainbowEffect: Codable, Equatable {
    static let minimumColors = 2
    static let maximumColors = 8
    static let defaultPalette = [
        RGBColor(r: 1, g: 0, b: 0), RGBColor(r: 1, g: 1, b: 0), RGBColor(r: 0, g: 1, b: 0),
        RGBColor(r: 0, g: 1, b: 1), RGBColor(r: 0, g: 0, b: 1), RGBColor(r: 1, g: 0, b: 1)
    ]

    var animation: RainbowAnimation = .wave
    var cycleSeconds = 5.0
    var palette = defaultPalette

    var effectivePalette: [RGBColor] {
        palette.count >= Self.minimumColors ? Array(palette.prefix(Self.maximumColors)) : Self.defaultPalette
    }

    var effectiveCycleSeconds: Double { min(30, max(1, cycleSeconds)) }
}

struct RainbowRenderer {
    let effect: RainbowEffect
    private let samples: [RGBColor]

    init(_ effect: RainbowEffect) {
        self.effect = effect
        let palette = effect.effectivePalette
        samples = palette.indices.flatMap { index -> [RGBColor] in
            let curve = OKLCHTransition(from: palette[index], to: palette[(index + 1) % palette.count])
            return (0..<64).map { curve.color(at: Double($0) / 64) }
        }
    }

    func color(elapsedSeconds: Double, spatialOffset: Double) -> RGBColor {
        let phase = elapsedSeconds / effect.effectiveCycleSeconds
        let index: Double
        switch effect.animation {
        case .wave: index = phase - spatialOffset
        case .reverseWave: index = phase + spatialOffset
        case .cycle, .pulse: index = phase
        }
        let position = (index - floor(index)) * Double(samples.count)
        let lower = Int(position) % samples.count
        let color = samples[lower].mixed(with: samples[(lower + 1) % samples.count], fraction: position - floor(position))
        return effect.animation == .pulse ? color.scaled(by: 0.2 + 0.8 * pow(cos(.pi * phase), 2)) : color
    }
}

extension RGBColor {
    func mixed(with other: RGBColor, fraction: Double) -> RGBColor {
        RGBColor(r: r + (other.r - r) * fraction, g: g + (other.g - g) * fraction, b: b + (other.b - b) * fraction)
    }

    func scaled(by gain: Double) -> RGBColor {
        RGBColor(r: r * gain, g: g * gain, b: b * gain)
    }
}

struct OKLCHTransition {
    private let from: RGBColor
    private let to: RGBColor
    private let start: OKLCH
    private let end: OKLCH

    init(from: RGBColor, to: RGBColor) {
        self.from = from.clamped()
        self.to = to.clamped()
        var a = OKLCH(self.from), b = OKLCH(self.to)
        if a.c < 0.000004 { a.h = b.h }
        if b.c < 0.000004 { b.h = a.h }
        if b.h - a.h > .pi { a.h += 2 * .pi }
        if b.h - a.h < -.pi { b.h += 2 * .pi }
        start = a
        end = b
    }

    func color(at t: Double) -> RGBColor {
        if t <= 0 { return from }
        if t >= 1 { return to }
        return OKLCH(l: start.l + (end.l - start.l) * t,
                     c: start.c + (end.c - start.c) * t,
                     h: start.h + (end.h - start.h) * t).sRGB()
    }
}

private struct OKLCH {
    var l: Double
    var c: Double
    var h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    // OKLab matrices and sRGB transfer function:
    // https://www.w3.org/TR/css-color-4/#color-conversion-code
    init(_ color: RGBColor) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(color.r), g = linear(color.g), b = linear(color.b)
        let x = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let y = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let z = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * x - 2.4285922050 * y + 0.4505937099 * z
        let bLab = 0.0259040371 * x + 0.7827717662 * y - 0.8086757660 * z
        self.init(l: 0.2104542553 * x + 0.7936177850 * y - 0.0040720468 * z, c: hypot(a, bLab), h: atan2(bLab, a))
    }

    func sRGB() -> RGBColor {
        let cosH = cos(h), sinH = sin(h)
        func rgb(_ chroma: Double) -> RGBColor {
            let a = chroma * cosH, b = chroma * sinH
            let x = l + 0.3963377774 * a + 0.2158037573 * b
            let y = l - 0.1055613458 * a - 0.0638541728 * b
            let z = l - 0.0894841775 * a - 1.2914855480 * b
            let x3 = x * x * x, y3 = y * y * y, z3 = z * z * z
            return RGBColor(r: 4.0767416621 * x3 - 3.3077115913 * y3 + 0.2309699292 * z3,
                            g: -1.2684380046 * x3 + 2.6097574011 * y3 - 0.3413193965 * z3,
                            b: -0.0041960863 * x3 - 0.7034186147 * y3 + 1.7076147010 * z3)
        }
        let gamut = -0.000001...1.000001
        func fits(_ color: RGBColor) -> Bool { gamut.contains(color.r) && gamut.contains(color.g) && gamut.contains(color.b) }
        var linear = rgb(c)
        if !fits(linear) {
            // Reduce chroma without shifting the interpolated hue or lightness.
            var low = 0.0, high = c
            for _ in 0..<15 {
                let middle = (low + high) / 2
                if fits(rgb(middle)) { low = middle } else { high = middle }
            }
            linear = rgb(low)
        }
        func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return RGBColor(r: encode(linear.r), g: encode(linear.g), b: encode(linear.b)).clamped()
    }
}
