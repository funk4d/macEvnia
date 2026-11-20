import AppKit
import CoreAudio
import Foundation

@main
enum ProfileSymbolsTests {
    static func main() throws {
        _ = NSApplication.shared
        var profile = AmbilightProfile.defaultProfile(name: "Saved Profile")
        let original = try JSONEncoder().encode(profile)
        var legacy = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        for key in ["iconName", "mode", "music", "solidColor", "gradient", "rainbow", "iconStyle", "iconColor"] {
            legacy.removeValue(forKey: key)
        }
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
        let savedProfiles = store.profiles
        let savedSelection = store.selectedProfileID
        store.beginEditing()
        let draft = store.addProfile(named: "Draft")
        store.updateSelected { $0.mode = .followMusic }
        store.deleteProfile(id: savedProfiles[0].id)
        precondition(store.hasUnsavedChanges && store.selectedProfileID == draft.id)
        store.cancelEditing()
        precondition(store.profiles == savedProfiles && store.selectedProfileID == savedSelection)
        store.beginEditing()
        store.updateSelected { $0.name = "Applied" }
        try store.commitEditing()
        store.beginEditing()
        store.updateSelected { $0.name = "Discarded" }
        store.cancelEditing()
        precondition(store.selectedProfile.name == "Applied")

        try testLightingProfiles()
        testMusicResponse()
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

    private static func testLightingProfiles() throws {
        let red = RGBColor(r: 1, g: 0, b: 0), blue = RGBColor(r: 0, g: 0, b: 1)
        let blackToWhite = OKLCHTransition(from: .black, to: .white)
        let gray = blackToWhite.color(at: 0.5)
        precondition(abs(gray.r - 0.3886) < 0.001 && abs(gray.g - gray.b) < 0.0001)
        let gradient = GradientEffect(startColor: red, endColor: blue,
                                      start: GradientPoint(x: 0.75, y: 0.75), end: GradientPoint(x: 0.25, y: 0.25))
        let colors = gradient.colors(at: [gradient.start, gradient.end, GradientPoint(x: 0.5, y: 0.5)])
        precondition(colors[0] == red && colors[1] == blue)
        precondition(colors[2] == OKLCHTransition(from: red, to: blue).color(at: 0.5))
        precondition(colors[2].r > 0.5 && colors[2].b > 0.5 && colors[2].g < 0.15)

        var effect = RainbowEffect(animation: .wave, cycleSeconds: 4, palette: [red, blue])
        let wave = RainbowRenderer(effect)
        precondition(wave.color(elapsedSeconds: 0, spatialOffset: 0) == red)
        precondition(wave.color(elapsedSeconds: 0, spatialOffset: 0.5) == blue)
        precondition(wave.color(elapsedSeconds: 1, spatialOffset: 0.25) == red)
        precondition(wave.color(elapsedSeconds: 4, spatialOffset: 0) == red)
        effect.animation = .reverseWave
        precondition(RainbowRenderer(effect).color(elapsedSeconds: 1, spatialOffset: 0.25) == blue)
        effect.animation = .cycle
        let cycle = RainbowRenderer(effect)
        precondition(cycle.color(elapsedSeconds: 2, spatialOffset: 0.25) == blue)
        effect.animation = .pulse
        let pulse = RainbowRenderer(effect)
        precondition(abs(pulse.color(elapsedSeconds: 2, spatialOffset: 0).b - 0.2) < 0.0001)

        var profile = AmbilightProfile.defaultProfile()
        profile.solidColor = blue
        profile.gradient = gradient
        profile.rainbow = effect
        profile.music = MusicEffect(dynamicColors: true, bassColor: red, trebleColor: blue, sensitivity: 1.75,
                                    smoothing: 0.7, brightness: 0.45)
        var oldMusic = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile.music)) as! [String: Any]
        oldMusic.removeValue(forKey: "smoothing")
        oldMusic.removeValue(forKey: "brightness")
        let migrated = try JSONDecoder().decode(MusicEffect.self, from: JSONSerialization.data(withJSONObject: oldMusic))
        precondition(migrated.dynamicColors && migrated.sensitivity == 1.75 && migrated.bassColor == red)
        precondition(migrated.smoothing == 0.3 && migrated.brightness == 1)
        profile.iconColor = red
        for mode in ProfileMode.allCases {
            profile.mode = mode
            for style in ProfileIconStyle.allCases {
                profile.iconStyle = style
                let copy = try JSONDecoder().decode(AmbilightProfile.self, from: JSONEncoder().encode(profile))
                precondition(copy == profile)
            }
        }
        profile.mode = .gradientColor
        precondition(profile.artwork == .gradient(gradient))
        profile.mode = .followVideo
        precondition(profile.artwork == .symbol("display"))
        let playback = PlaybackMode.profile(profile.id)
        let restored = try JSONDecoder().decode(PlaybackMode.self, from: JSONEncoder().encode(playback))
        precondition(restored == playback)
        print("PASS: OKLCH endpoints and midpoint, four animations, profile artwork and playback persistence")
    }

    private static func testMusicResponse() {
        let rate = 48_000.0
        for (band, tone) in [60.0, 800.0, 6_000.0].enumerated() {
            let signal = (0..<4800).map { Float(0.3 * sin(2 * Double.pi * tone * Double($0) / rate)) }
            var spectrum = MusicSpectrum(sampleRate: rate)
            let result = signal.withUnsafeBufferPointer { spectrum.consume($0) }!
            precondition(result[band] > 0.18)
            for other in 0..<3 where other != band { precondition(result[band] > result[other] * 5) }
        }
        let positions = [1.0, 0.5, 0.0].flatMap { y in
            [GradientPoint(x: 0, y: y), GradientPoint(x: 1, y: y)]
        }
        testStereoAudioBuffers()
        testStereoLights(positions: positions)

        var fixed = MusicEffect(smoothing: 0)
        let mono = MusicRenderer(effect: fixed, positions: positions)
        let quiet = mono.frame(levels: .init(left: MusicBands(0.007, 0, 0), right: .zero), elapsed: 0.02)
        precondition(quiet[0].b > 0 && quiet[0] == quiet[1] && quiet[2...].allSatisfy { $0 == .black })
        let medium = mono.frame(levels: .init(mono: MusicBands(0, 0, 0.06)), elapsed: 0.02)
        precondition(medium[0].b > medium[2].b && medium[2].b > 0)
        precondition(medium[0] == medium[1] && medium[2] == medium[3] && medium[4] == .black && medium[5] == .black)
        precondition(mono.frame(levels: .init(mono: MusicBands(0.06, 0, 0)), elapsed: 0.02) == medium)
        let loud = StereoMusicLevels(mono: MusicBands(repeating: 0.5))
        let uniformColor = mono.frame(levels: loud, elapsed: 0.02)
        precondition(uniformColor.allSatisfy { $0 == fixed.color })
        fixed.brightness = 0.25
        mono.update(effect: fixed)
        precondition(mono.frame(levels: loud, elapsed: 0.02)[0] == fixed.color.scaled(by: 0.25))
        precondition(mono.frame(levels: .zero, elapsed: 0.02).allSatisfy { $0 == .black })
        let soft = MusicRenderer(effect: MusicEffect(smoothing: 0.9), positions: positions)
        let attack = soft.frame(levels: loud, elapsed: 0.02)
        precondition(attack[0].b > 0 && attack[0].b < uniformColor[0].b)
        precondition(soft.frame(levels: .zero, elapsed: 0.02)[0].b > 0)
        print("PASS: planar and interleaved stereo, spatial music layers, bass waves, and single-color fill")
    }

    private static func testStereoAudioBuffers() {
        let rate = 48_000.0
        func tone(_ frequency: Double) -> [Float] {
            (0..<4800).map { Float(0.3 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        }
        var bass = tone(60), treble = tone(6000)
        var packed = zip(bass, treble).flatMap { [$0.0, $0.1] }
        var analyzer = StereoMusicSpectrum(sampleRate: rate)
        let interleaved = packed.withUnsafeMutableBufferPointer { samples in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer(samples, channels: 2))
            return analyzer.consumeAudio(&input)
        }!
        precondition(interleaved.left.x > 0.18 && interleaved.left.z < 0.01)
        precondition(interleaved.right.z > 0.18 && interleaved.right.x < 0.01)
        analyzer = StereoMusicSpectrum(sampleRate: rate)
        let planar = bass.withUnsafeMutableBufferPointer { left in
            treble.withUnsafeMutableBufferPointer { right in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                list[0] = audioBuffer(left, channels: 1)
                list[1] = audioBuffer(right, channels: 1)
                return analyzer.consumeAudio(list.unsafePointer)
            }
        }!
        precondition(planar.left == interleaved.left && planar.right == interleaved.right)
    }

    private static func audioBuffer(_ samples: UnsafeMutableBufferPointer<Float>, channels: UInt32) -> AudioBuffer {
        AudioBuffer(mNumberChannels: channels,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.stride),
                    mData: samples.baseAddress)
    }

    private static func testStereoLights(positions: [GradientPoint]) {
        let dynamic = MusicRenderer(effect: MusicEffect(dynamicColors: true, smoothing: 0), positions: positions)
        let bass = dynamic.frame(levels: .init(mono: MusicBands(0.4, 0, 0)), elapsed: 0.02)
        precondition(bass[0].r > 0.8 && bass[0] == bass[1] && bass[4] == .black && bass[5] == .black)
        let wave = dynamic.frame(levels: .zero, elapsed: 0.2)
        precondition(wave[0] == .black && wave[1] == .black && wave[2].r > 0.15 && wave[2] == wave[3])
        precondition(dynamic.frame(levels: .zero, elapsed: 0.2).allSatisfy { $0 == .black })

        let highsRight = dynamic.frame(levels: .init(left: .zero, right: MusicBands(0, 0, 0.35)), elapsed: 0.02)
        precondition(highsRight.prefix(4).allSatisfy { $0 == .black })
        precondition(highsRight[5].b > highsRight[4].b * 8 && highsRight[5].b > highsRight[5].r)
        let highsLeft = dynamic.frame(levels: .init(left: MusicBands(0, 0, 0.35), right: .zero), elapsed: 0.02)
        precondition(abs(highsLeft[4].b - highsRight[5].b) < 0.00001)

        let mids = dynamic.frame(levels: .init(mono: MusicBands(0, 0.15, 0)), elapsed: 0.02)
        precondition(mids[2].g > mids[2].r && mids[2] == mids[3])
        precondition(mids[0] == .black && mids[4] == .black)
    }
}
