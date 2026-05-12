import Foundation
import IOKit.hid

struct LampArrayAttributes {
    var lampCount: Int
    var widthMicrometers: UInt32
    var heightMicrometers: UInt32
    var depthMicrometers: UInt32
    var kind: UInt32
    var minUpdateIntervalMicroseconds: UInt32

    var maxUpdateHz: Double {
        guard minUpdateIntervalMicroseconds > 0 else { return 50 }
        return 1_000_000.0 / Double(minUpdateIntervalMicroseconds)
    }
}

struct LampAttributes {
    var id: Int
    var xMicrometers: UInt32
    var yMicrometers: UInt32
    var zMicrometers: UInt32
    var updateLatencyMicroseconds: UInt32
    var purpose: UInt32
    var redLevels: UInt8
    var greenLevels: UInt8
    var blueLevels: UInt8
    var intensityLevels: UInt8
    var isProgrammable: Bool
    var inputBinding: UInt8
}

enum LampArrayError: Error, LocalizedError {
    case notFound
    case openFailed(IOReturn)
    case reportFailed(String, IOReturn)
    case malformedReport(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Philips Evnia LampArray device was not found."
        case .openFailed(let code):
            return "Could not open LampArray HID device: \(code)."
        case .reportFailed(let name, let code):
            return "\(name) HID report failed: \(code)."
        case .malformedReport(let name):
            return "\(name) HID report returned malformed data."
        }
    }
}

final class LampArrayDevice {
    static let vendorID = 0x0CF2
    static let productID = 0xB215
    static let usagePage = 0x59
    static let usage = 0x01

    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDDeviceUsagePageKey: Self.usagePage,
            kIOHIDDeviceUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = devices.first else {
            throw LampArrayError.notFound
        }
        device = first

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw LampArrayError.openFailed(result)
        }
    }

    deinit {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func arrayAttributes() throws -> LampArrayAttributes {
        let report = try getFeatureReport(id: 0x01, length: 23, name: "Array attributes")
        guard report.count >= 23 else { throw LampArrayError.malformedReport("Array attributes") }
        return LampArrayAttributes(
            lampCount: Int(report.uInt16LE(at: 1)),
            widthMicrometers: report.uInt32LE(at: 3),
            heightMicrometers: report.uInt32LE(at: 7),
            depthMicrometers: report.uInt32LE(at: 11),
            kind: report.uInt32LE(at: 15),
            minUpdateIntervalMicroseconds: report.uInt32LE(at: 19)
        )
    }

    func lampAttributes(count: Int) throws -> [LampAttributes] {
        try (0..<count).map { id in
            try requestLampAttributes(id: id)
            return try readLampAttributes()
        }
    }

    func setAutonomous(_ enabled: Bool) throws {
        try setFeatureReport([0x06, enabled ? 1 : 0], name: "LampArray control")
    }

    func setRange(start: Int, end: Int, rgb: RGBColor, intensity: UInt8 = 1) throws {
        var report: [UInt8] = [0x05, 0x01]
        report.appendUInt16LE(UInt16(start))
        report.appendUInt16LE(UInt16(end))
        report.append(rgb.byteR)
        report.append(rgb.byteG)
        report.append(rgb.byteB)
        report.append(intensity)
        try setFeatureReport(report, name: "Range update")
    }

    func setFrame(_ colors: [RGBColor]) throws {
        let chunkSize = 8
        var start = 0
        while start < colors.count {
            let end = min(colors.count, start + chunkSize)
            var report: [UInt8] = [0x04, UInt8(end - start), end == colors.count ? 0x01 : 0x00]
            for index in 0..<chunkSize {
                let lampID = start + index
                report.appendUInt16LE(UInt16(lampID < end ? lampID : 0))
            }
            for index in 0..<chunkSize {
                if start + index < end {
                    let color = colors[start + index].clamped()
                    let intensity: UInt8 = (color.r > 0 || color.g > 0 || color.b > 0) ? 1 : 0
                    report.append(color.byteR)
                    report.append(color.byteG)
                    report.append(color.byteB)
                    report.append(intensity)
                } else {
                    report.append(contentsOf: [0, 0, 0, 0])
                }
            }
            try setFeatureReport(report, name: "Multi update")
            start = end
        }
    }

    private func requestLampAttributes(id: Int) throws {
        var report: [UInt8] = [0x02]
        report.appendUInt16LE(UInt16(id))
        try setFeatureReport(report, name: "Lamp attributes request")
    }

    private func readLampAttributes() throws -> LampAttributes {
        let report = try getFeatureReport(id: 0x03, length: 29, name: "Lamp attributes response")
        guard report.count >= 29 else { throw LampArrayError.malformedReport("Lamp attributes response") }
        return LampAttributes(
            id: Int(report.uInt16LE(at: 1)),
            xMicrometers: report.uInt32LE(at: 3),
            yMicrometers: report.uInt32LE(at: 7),
            zMicrometers: report.uInt32LE(at: 11),
            updateLatencyMicroseconds: report.uInt32LE(at: 15),
            purpose: report.uInt32LE(at: 19),
            redLevels: report[23],
            greenLevels: report[24],
            blueLevels: report[25],
            intensityLevels: report[26],
            isProgrammable: report[27] != 0,
            inputBinding: report[28]
        )
    }

    private func getFeatureReport(id: UInt8, length: Int, name: String) throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        report[0] = id
        var reportLength = report.count
        let result = report.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(id),
                pointer.baseAddress!,
                &reportLength
            )
        }
        guard result == kIOReturnSuccess else {
            throw LampArrayError.reportFailed(name, result)
        }
        return Array(report.prefix(reportLength))
    }

    private func setFeatureReport(_ report: [UInt8], name: String) throws {
        var copy = report
        let result = copy.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(report[0]),
                pointer.baseAddress!,
                pointer.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw LampArrayError.reportFailed(name, result)
        }
    }
}

private extension RGBColor {
    var byteR: UInt8 { UInt8((min(1, max(0, r)) * 255).rounded()) }
    var byteG: UInt8 { UInt8((min(1, max(0, g)) * 255).rounded()) }
    var byteB: UInt8 { UInt8((min(1, max(0, b)) * 255).rounded()) }
}

private extension Array where Element == UInt8 {
    func uInt16LE(at index: Int) -> UInt16 {
        UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }

    func uInt32LE(at index: Int) -> UInt32 {
        UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00FF))
        append(UInt8((value >> 8) & 0x00FF))
    }
}
