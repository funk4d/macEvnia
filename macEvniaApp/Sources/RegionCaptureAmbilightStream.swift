import CoreGraphics
import Foundation

final class RegionCaptureAmbilightStream: ScreenColorStream {
    private let attributes: LampArrayAttributes
    private let lamps: [LampAttributes]
    private let outputQueue: DispatchQueue
    private var profile: AmbilightProfile
    private var timer: DispatchSourceTimer?
    private var displayID: CGDirectDisplayID?
    private var displayBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var sourceSize = CGSize(width: 1, height: 1)
    private var isCapturing = false
    private var consecutiveFailures = 0
    private var lastLoggedFrameKey = ""

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
                completion(.failure(RegionCaptureError.displayNotFound))
                return
            }

            self.prepareDisplay(displayID)
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
                if let displayID = DisplayCatalog.displayID(for: profile) {
                    self.prepareDisplay(displayID)
                }
                self.consecutiveFailures = 0
            }

            if oldFPS != profile.clampedCaptureFPS || oldQuality != profile.clampedScreenshotQuality {
                self.lastLoggedFrameKey = ""
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

    private func prepareDisplay(_ displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.displayBounds = CGDisplayBounds(displayID)
        self.sourceSize = CGSize(
            width: max(1, CGDisplayPixelsWide(displayID)),
            height: max(1, CGDisplayPixelsHigh(displayID))
        )
        self.lastLoggedFrameKey = ""
        DebugLog.write("Tiny region capture configured source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) displayBounds=\(Int(displayBounds.width))x\(Int(displayBounds.height)) quality=\(profile.clampedScreenshotQuality)% regionRadius=\(regionRadius())px")
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
            DebugLog.write("Tiny region capture frame failed: \(error.localizedDescription)")
            if consecutiveFailures >= 5 {
                onError?(error)
            }
        }
    }

    private func captureOnce() throws -> [RGBColor] {
        guard displayID != nil else {
            throw RegionCaptureError.displayNotFound
        }

        let radius = regionRadius()
        let points = lampPoints()
        var totalPixels = 0
        var largestWidth = 0
        var largestHeight = 0

        let colors = try points.map { point in
            let rect = captureRect(center: point, radius: radius)
            guard rect.width >= 1, rect.height >= 1 else {
                return RGBColor.black
            }

            let imageOptions: CGWindowImageOption = [
                .boundsIgnoreFraming,
                .shouldBeOpaque,
                .nominalResolution,
            ]
            guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, imageOptions) else {
                throw RegionCaptureError.emptyFrame
            }

            let width = max(1, image.width)
            let height = max(1, image.height)
            totalPixels += width * height
            largestWidth = max(largestWidth, width)
            largestHeight = max(largestHeight, height)

            guard let provider = image.dataProvider,
                  let data = provider.data,
                  let pointer = CFDataGetBytePtr(data) else {
                throw RegionCaptureError.emptyFrame
            }

            let bytesPerRow = image.bytesPerRow
            let bytesPerPixel = max(1, (image.bitsPerPixel + 7) / 8)
            guard bytesPerPixel >= 4 else {
                throw RegionCaptureError.unsupportedPixelFormat
            }

            return averageRegionBGRA(
                pointer: pointer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: bytesPerPixel,
                stride: max(1, profile.effectiveSampleStride)
            )
        }

        let frameKey = "\(points.count)-\(largestWidth)x\(largestHeight)-\(totalPixels)-q\(profile.clampedScreenshotQuality)-r\(radius)"
        if frameKey != lastLoggedFrameKey {
            lastLoggedFrameKey = frameKey
            DebugLog.write("Tiny region actual regions=\(points.count) largestCGImage=\(largestWidth)x\(largestHeight) totalPixels=\(totalPixels) source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) quality=\(profile.clampedScreenshotQuality)% radius=\(radius)px")
        }

        return colors
    }

    private func regionRadius() -> Int {
        let qualityScale = Double(profile.clampedScreenshotQuality) / 100.0
        return max(1, Int((Double(profile.sampleRadius) * qualityScale).rounded()))
    }

    private func captureRect(center: CGPoint, radius: Int) -> CGRect {
        let diameter = CGFloat(radius * 2 + 1)
        let proposed = CGRect(
            x: center.x - CGFloat(radius),
            y: center.y - CGFloat(radius),
            width: diameter,
            height: diameter
        )
        return proposed.intersection(displayBounds).integral
    }

    private func lampPoints() -> [CGPoint] {
        let boxWidth = max(1, Double(attributes.widthMicrometers))
        let boxHeight = max(1, Double(attributes.heightMicrometers))
        return lamps.map { lamp in
            let x = displayBounds.minX + CGFloat(Double(lamp.xMicrometers) / boxWidth * Double(max(1, sourceSize.width - 1)))
            let y = displayBounds.minY + CGFloat(Double(lamp.yMicrometers) / boxHeight * Double(max(1, sourceSize.height - 1)))
            return CGPoint(
                x: min(displayBounds.maxX - 1, max(displayBounds.minX, x)),
                y: min(displayBounds.maxY - 1, max(displayBounds.minY, y))
            )
        }
    }
}

private enum RegionCaptureError: Error, LocalizedError {
    case displayNotFound
    case emptyFrame
    case unsupportedPixelFormat

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "No tiny region capture display was found."
        case .emptyFrame:
            return "Tiny region capture returned an empty screenshot frame."
        case .unsupportedPixelFormat:
            return "Tiny region capture returned an unsupported pixel format."
        }
    }
}

private func averageRegionBGRA(
    pointer: UnsafePointer<UInt8>,
    width: Int,
    height: Int,
    bytesPerRow: Int,
    bytesPerPixel: Int,
    stride: Int
) -> RGBColor {
    let step = max(1, stride)
    var red = 0
    var green = 0
    var blue = 0
    var count = 0

    var y = 0
    while y < height {
        let row = pointer + y * bytesPerRow
        var x = 0
        while x < width {
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
