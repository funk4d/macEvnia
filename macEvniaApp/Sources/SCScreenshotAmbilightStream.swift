import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class SCScreenshotAmbilightStream: ScreenColorStream, @unchecked Sendable {
    private let attributes: LampArrayAttributes
    private let lamps: [LampAttributes]
    private let outputQueue: DispatchQueue
    private var profile: AmbilightProfile
    private var timer: DispatchSourceTimer?
    private var contentFilter: SCContentFilter?
    private var streamConfiguration: SCStreamConfiguration?
    private var sourcePixelSize = CGSize(width: 1, height: 1)
    private var isCapturing = false
    private var isStopped = false
    private var consecutiveFailures = 0
    private var generation = 0
    private var lastLoggedActualImageKey = ""

    var onColors: (([RGBColor]) -> Void)?
    var onError: ((Error) -> Void)?

    init(
        profile: AmbilightProfile,
        attributes: LampArrayAttributes,
        lamps: [LampAttributes],
        outputQueue: DispatchQueue
    ) {
        self.profile = profile
        self.attributes = attributes
        self.lamps = lamps
        self.outputQueue = outputQueue
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        outputQueue.async {
            self.isStopped = false
            self.generation += 1
            let generation = self.generation
            Task {
                do {
                    try await self.prepareCaptureObjects()
                    let colors = try await self.captureOnce()
                    self.outputQueue.async {
                        guard !self.isStopped, generation == self.generation else { return }
                        if !colors.isEmpty {
                            self.onColors?(colors)
                        }
                        self.scheduleTimer()
                        completion(.success(()))
                    }
                } catch {
                    self.outputQueue.async {
                        guard generation == self.generation else { return }
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func update(profile: AmbilightProfile) {
        outputQueue.async {
            let oldFPS = self.profile.clampedCaptureFPS
            let oldDisplayID = self.profile.displayID
            let oldQuality = self.profile.clampedScreenshotQuality
            self.profile = profile

            if oldDisplayID != profile.displayID || oldQuality != profile.clampedScreenshotQuality {
                self.generation += 1
                let generation = self.generation
                Task {
                    do {
                        try await self.prepareCaptureObjects()
                        self.outputQueue.async {
                            guard !self.isStopped, generation == self.generation else { return }
                            self.consecutiveFailures = 0
                            self.scheduleTimer()
                        }
                    } catch {
                        self.outputQueue.async {
                            guard generation == self.generation else { return }
                            self.reportFrameError(error)
                        }
                    }
                }
            } else if oldFPS != profile.clampedCaptureFPS {
                self.scheduleTimer()
            }
        }
    }

    func stop() {
        outputQueue.async {
            self.isStopped = true
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
            self.isCapturing = false
            self.contentFilter = nil
            self.streamConfiguration = nil
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let intervalNanoseconds = UInt64(max(1.0 / Double(max(1, profile.clampedCaptureFPS)), 0.02) * 1_000_000_000)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNanoseconds)), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard !isStopped, !isCapturing else { return }
        guard contentFilter != nil, streamConfiguration != nil else { return }
        isCapturing = true
        let generation = self.generation

        Task {
            do {
                let colors = try await self.captureOnce()
                self.outputQueue.async {
                    guard !self.isStopped, generation == self.generation else { return }
                    self.isCapturing = false
                    self.consecutiveFailures = 0
                    if !colors.isEmpty {
                        self.onColors?(colors)
                    }
                }
            } catch {
                self.outputQueue.async {
                    guard generation == self.generation else { return }
                    self.isCapturing = false
                    self.reportFrameError(error)
                }
            }
        }
    }

    private func prepareCaptureObjects() async throws {
        guard let displayID = DisplayCatalog.displayID(for: profile) else {
            throw SCScreenshotCaptureError.displayNotFound
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SCScreenshotCaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }

        let configuration = SCStreamConfiguration()
        let pixelWidth = max(1, Int(CGDisplayPixelsWide(displayID)))
        let pixelHeight = max(1, Int(CGDisplayPixelsHigh(displayID)))
        let outputSize = scaledOutputSize(sourceWidth: pixelWidth, sourceHeight: pixelHeight)
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, profile.clampedCaptureFPS)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .nominal
            configuration.shouldBeOpaque = true
        }
        if #available(macOS 15.0, *) {
            configuration.captureDynamicRange = .SDR
        }

        self.contentFilter = filter
        self.streamConfiguration = configuration
        self.sourcePixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        self.lastLoggedActualImageKey = ""
        DebugLog.write("SCScreenshotManager configured source=\(pixelWidth)x\(pixelHeight) output=\(outputSize.width)x\(outputSize.height) quality=\(profile.clampedScreenshotQuality)%")
    }

    private func captureOnce() async throws -> [RGBColor] {
        guard #available(macOS 14.0, *) else {
            throw SCScreenshotCaptureError.unavailable
        }
        guard let contentFilter, let streamConfiguration else {
            throw SCScreenshotCaptureError.notPrepared
        }

        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, profile.clampedCaptureFPS)))
        let image = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: streamConfiguration)

        guard let provider = image.dataProvider,
              let data = provider.data,
              let pointer = CFDataGetBytePtr(data) else {
            throw SCScreenshotCaptureError.emptyFrame
        }

        let width = max(1, image.width)
        let height = max(1, image.height)
        let actualImageKey = "\(width)x\(height)-q\(profile.clampedScreenshotQuality)"
        if actualImageKey != lastLoggedActualImageKey {
            lastLoggedActualImageKey = actualImageKey
            DebugLog.write("SCScreenshotManager actual CGImage=\(width)x\(height) requested=\(streamConfiguration.width)x\(streamConfiguration.height) source=\(Int(sourcePixelSize.width))x\(Int(sourcePixelSize.height)) quality=\(profile.clampedScreenshotQuality)%")
        }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(1, (image.bitsPerPixel + 7) / 8)
        guard bytesPerPixel >= 4 else {
            throw SCScreenshotCaptureError.unsupportedPixelFormat
        }

        let points = lampPoints(width: width, height: height)
        let sampleScale = Double(max(width, height)) / max(1.0, max(sourcePixelSize.width, sourcePixelSize.height))
        let scaledRadius = max(1, Int((Double(profile.sampleRadius) * sampleScale).rounded()))
        let scaledStride = max(1, Int((Double(max(1, profile.sampleStride)) * sampleScale).rounded()))
        return points.map { point in
            averageSCScreenshotBGRA(
                pointer: pointer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: bytesPerPixel,
                centerX: point.x,
                centerY: point.y,
                radius: scaledRadius,
                stride: scaledStride
            )
        }
    }

    private func scaledOutputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let longestSide = max(1, min(max(sourceWidth, sourceHeight), profile.screenshotLongestSide))
        let scale = Double(longestSide) / Double(max(sourceWidth, sourceHeight))
        return (
            width: max(1, Int((Double(sourceWidth) * scale).rounded())),
            height: max(1, Int((Double(sourceHeight) * scale).rounded()))
        )
    }

    private func lampPoints(width: Int, height: Int) -> [(x: Int, y: Int)] {
        let boxWidth = max(1, Double(attributes.widthMicrometers))
        let boxHeight = max(1, Double(attributes.heightMicrometers))
        return lamps.map { lamp in
            let x = Int((Double(lamp.xMicrometers) / boxWidth * Double(width - 1)).rounded())
            let y = Int((Double(lamp.yMicrometers) / boxHeight * Double(height - 1)).rounded())
            return (min(width - 1, max(0, x)), min(height - 1, max(0, y)))
        }
    }

    private func reportFrameError(_ error: Error) {
        consecutiveFailures += 1
        DebugLog.write("SCScreenshotManager frame failed: \(error.localizedDescription)")
        if consecutiveFailures >= 5 {
            onError?(error)
        }
    }
}

private enum SCScreenshotCaptureError: Error, LocalizedError {
    case displayNotFound
    case unavailable
    case notPrepared
    case emptyFrame
    case unsupportedPixelFormat

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "No SCScreenshotManager display was found."
        case .unavailable:
            return "SCScreenshotManager frame backend requires macOS 14.0 or newer."
        case .notPrepared:
            return "SCScreenshotManager backend is not prepared."
        case .emptyFrame:
            return "SCScreenshotManager returned an empty frame."
        case .unsupportedPixelFormat:
            return "SCScreenshotManager returned an unsupported pixel format."
        }
    }
}

private func averageSCScreenshotBGRA(
    pointer: UnsafePointer<UInt8>,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    bytesPerPixel: Int,
    centerX: Int,
    centerY: Int,
    radius: Int,
    stride: Int
) -> RGBColor {
    let step = max(1, stride)
    let left = max(0, centerX - radius)
    let right = min(width - 1, centerX + radius)
    let top = max(0, centerY - radius)
    let bottom = min(height - 1, centerY + radius)

    var red = 0
    var green = 0
    var blue = 0
    var count = 0

    var y = top
    while y <= bottom {
        let row = pointer + y * bytesPerRow
        var x = left
        while x <= right {
            let pixel = row + x * bytesPerPixel
            blue += Int(pixel[0])
            green += Int(pixel[1])
            red += Int(pixel[2])
            count += 1
            x += step
        }
        y += step
    }

    guard count > 0 else { return .black }
    return RGBColor(
        r: Double(red) / Double(count) / 255.0,
        g: Double(green) / Double(count) / 255.0,
        b: Double(blue) / Double(count) / 255.0
    )
}
