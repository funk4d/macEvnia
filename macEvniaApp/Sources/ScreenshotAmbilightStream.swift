import CoreGraphics
import Foundation

final class ScreenshotAmbilightStream: ScreenColorStream {
    private let attributes: LampArrayAttributes
    private let lamps: [LampAttributes]
    private let outputQueue: DispatchQueue
    private var profile: AmbilightProfile
    private var timer: DispatchSourceTimer?
    private var displayID: CGDirectDisplayID?
    private var sourceSize = CGSize(width: 1, height: 1)
    private var isCapturing = false
    private var consecutiveFailures = 0

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
            guard let displayID = DisplayCatalog.displayID(for: self.profile) else {
                completion(.failure(ScreenshotCaptureError.displayNotFound))
                return
            }

            self.displayID = displayID
            self.sourceSize = CGSize(
                width: max(1, CGDisplayPixelsWide(displayID)),
                height: max(1, CGDisplayPixelsHigh(displayID))
            )

            do {
                let colors = try self.captureOnce()
                if !colors.isEmpty {
                    self.onColors?(colors)
                }
                self.scheduleTimer()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func update(profile: AmbilightProfile) {
        outputQueue.async {
            let oldFPS = self.profile.clampedCaptureFPS
            let oldDisplayID = self.profile.displayID
            let oldQuality = self.profile.clampedScreenshotQuality
            self.profile = profile

            if oldDisplayID != profile.displayID {
                self.displayID = DisplayCatalog.displayID(for: profile)
                if let displayID = self.displayID {
                    self.sourceSize = CGSize(
                        width: max(1, CGDisplayPixelsWide(displayID)),
                        height: max(1, CGDisplayPixelsHigh(displayID))
                    )
                }
                self.consecutiveFailures = 0
            }

            if oldFPS != profile.clampedCaptureFPS || oldQuality != profile.clampedScreenshotQuality {
                self.scheduleTimer()
            }
        }
    }

    func stop() {
        outputQueue.async {
            self.timer?.cancel()
            self.timer = nil
            self.isCapturing = false
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
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let colors = try captureOnce()
            consecutiveFailures = 0
            if !colors.isEmpty {
                onColors?(colors)
            }
        } catch {
            consecutiveFailures += 1
            DebugLog.write("CoreGraphics screenshot frame failed: \(error.localizedDescription)")
            if consecutiveFailures >= 5 {
                onError?(error)
            }
        }
    }

    private func captureOnce() throws -> [RGBColor] {
        guard let displayID else {
            throw ScreenshotCaptureError.displayNotFound
        }

        let rect = CGDisplayBounds(displayID)
        let imageOptions: CGWindowImageOption = [
            .boundsIgnoreFraming,
            .shouldBeOpaque,
            .nominalResolution,
        ]

        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, imageOptions) else {
            throw ScreenshotCaptureError.emptyFrame
        }

        guard let provider = image.dataProvider,
              let data = provider.data,
              let pointer = CFDataGetBytePtr(data) else {
            throw ScreenshotCaptureError.emptyFrame
        }

        let sourceWidth = max(1, image.width)
        let sourceHeight = max(1, image.height)
        let bytesPerRow = image.bytesPerRow
        let bitsPerPixel = image.bitsPerPixel
        let bytesPerPixel = max(1, (bitsPerPixel + 7) / 8)
        guard bytesPerPixel >= 4 else {
            throw ScreenshotCaptureError.unsupportedPixelFormat
        }
        sourceSize = CGSize(width: sourceWidth, height: sourceHeight)

        let points = lampPoints(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        return points.map { point in
            return averageScreenshotBGRA(
                pointer: pointer,
                width: sourceWidth,
                height: sourceHeight,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: bytesPerPixel,
                centerX: point.x,
                centerY: point.y,
                radius: profile.sampleRadius,
                stride: effectiveSampleStride()
            )
        }
    }

    private func effectiveSampleStride() -> Int {
        profile.effectiveSampleStride
    }

    private func lampPoints(sourceWidth: Int, sourceHeight: Int) -> [(x: Int, y: Int)] {
        let boxWidth = max(1, Double(attributes.widthMicrometers))
        let boxHeight = max(1, Double(attributes.heightMicrometers))
        return lamps.map { lamp in
            let x = Int((Double(lamp.xMicrometers) / boxWidth * Double(sourceWidth - 1)).rounded())
            let y = Int((Double(lamp.yMicrometers) / boxHeight * Double(sourceHeight - 1)).rounded())
            return (min(sourceWidth - 1, max(0, x)), min(sourceHeight - 1, max(0, y)))
        }
    }

}

private enum ScreenshotCaptureError: Error, LocalizedError {
    case displayNotFound
    case emptyFrame
    case unsupportedPixelFormat

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "No screenshot display was found."
        case .emptyFrame:
            return "CoreGraphics returned an empty MSS-style screenshot frame."
        case .unsupportedPixelFormat:
            return "CoreGraphics returned an unsupported screenshot pixel format."
        }
    }
}

private func averageScreenshotBGRA(
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
