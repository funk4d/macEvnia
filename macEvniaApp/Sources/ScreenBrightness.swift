import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

private typealias IOAVServiceRef = AnyObject

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: IOAVServiceRef, _ chipAddress: UInt32, _ offset: UInt32, _ data: UnsafePointer<UInt8>, _ length: UInt32) -> Int32

@_silgen_name("CGDisplayIOServicePort")
private func macEvniaCGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

/// DDC/CI brightness control for the connected external monitor (Philips Evnia).
/// Tries the native IODisplay brightness parameter first, then falls back to
/// DDC/CI VCP 0x10 via `IOAVServiceWriteI2C`. The internal MacBook backlight is
/// not touched unless there is no external display and no profile display is set.
enum ScreenBrightness {
    private static let defaultsKey = "macevnia.monitorBrightness"
    private static let lock = NSLock()
    private static var cachedService: IOAVServiceRef?

    static func isAvailable(for profile: AmbilightProfile? = nil) -> Bool {
        if current(for: profile) != nil {
            return true
        }
        return ddcService(useCache: true) != nil
    }

    static func invalidate(reason: String) {
        lock.lock()
        cachedService = nil
        lock.unlock()
        DebugLog.write("Monitor brightness cache invalidated: \(reason)")
    }

    /// 0...100, last value successfully written. Defaults to 50 on first launch.
    static func lastKnown(for profile: AmbilightProfile? = nil) -> Int {
        if let current = current(for: profile) {
            return current
        }
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int {
            return max(0, min(100, stored))
        }
        return 50
    }

    static func current(for profile: AmbilightProfile? = nil) -> Int? {
        guard let service = displayParameterService(for: profile) else {
            return nil
        }

        var floatValue: Float = 0
        let floatStatus = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &floatValue)
        if floatStatus == kIOReturnSuccess, floatValue.isFinite {
            return max(0, min(100, Int((Double(floatValue) * 100.0).rounded())))
        }

        var integerValue: Int32 = 0
        var minValue: Int32 = 0
        var maxValue: Int32 = 0
        let integerStatus = IODisplayGetIntegerRangeParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            &integerValue,
            &minValue,
            &maxValue
        )
        guard integerStatus == kIOReturnSuccess, maxValue > minValue else {
            return nil
        }

        let ratio = Double(integerValue - minValue) / Double(maxValue - minValue)
        return max(0, min(100, Int((ratio * 100.0).rounded())))
    }

    @discardableResult
    static func set(_ percent: Int, for profile: AmbilightProfile? = nil) -> Bool {
        let value = max(0, min(100, percent))

        if setIODisplayBrightness(value, for: profile) {
            UserDefaults.standard.set(value, forKey: defaultsKey)
            return true
        }

        if setDDCBrightness(value, useCache: true) || setDDCBrightness(value, useCache: false) {
            UserDefaults.standard.set(value, forKey: defaultsKey)
            return true
        }

        DebugLog.write("Monitor brightness: no writable brightness backend, value=\(value)")
        return false
    }

    private static func setIODisplayBrightness(_ percent: Int, for profile: AmbilightProfile?) -> Bool {
        guard let service = displayParameterService(for: profile) else {
            return false
        }

        let floatValue = Float(Double(percent) / 100.0)
        let floatStatus = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, floatValue)
        if floatStatus == kIOReturnSuccess {
            DebugLog.write("Monitor brightness set via IODisplay: \(percent)%")
            return true
        }

        var current: Int32 = 0
        var minValue: Int32 = 0
        var maxValue: Int32 = 0
        let rangeStatus = IODisplayGetIntegerRangeParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            &current,
            &minValue,
            &maxValue
        )
        if rangeStatus == kIOReturnSuccess, maxValue > minValue {
            let scaled = minValue + Int32((Double(maxValue - minValue) * Double(percent) / 100.0).rounded())
            let integerStatus = IODisplaySetIntegerParameter(service, 0, kIODisplayBrightnessKey as CFString, scaled)
            if integerStatus == kIOReturnSuccess {
                DebugLog.write("Monitor brightness set via IODisplay integer: \(percent)%")
                return true
            }
            DebugLog.write("Monitor brightness IODisplay integer write failed: status=\(formatIOReturn(integerStatus)), value=\(percent)")
        } else {
            DebugLog.write("Monitor brightness IODisplay float write failed: status=\(formatIOReturn(floatStatus)), value=\(percent)")
        }

        return false
    }

    private static func setDDCBrightness(_ percent: Int, useCache: Bool) -> Bool {
        let value = max(0, min(100, percent))
        guard let svc = ddcService(useCache: useCache) else {
            DebugLog.write("Monitor brightness: no external IOAVService available")
            return false
        }

        // DDC/CI VCP set: 0x84 0x03 0x10 hi lo CHK
        // CHK = XOR over (0x6E, 0x51, packet bytes)
        var packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, UInt8(value)]
        var chk: UInt8 = 0x6E ^ 0x51
        for b in packet { chk ^= b }
        packet.append(chk)

        let status = packet.withUnsafeBufferPointer { ptr -> Int32 in
            IOAVServiceWriteI2C(svc, 0x37, 0x51, ptr.baseAddress!, UInt32(ptr.count))
        }
        if status == 0 {
            DebugLog.write("Monitor brightness set via DDC/CI: \(value)%")
            return true
        }
        invalidate(reason: "DDC write failed \(formatIOReturn(status))")
        DebugLog.write("Monitor brightness DDC write failed: status=\(formatIOReturn(status)), value=\(value), useCache=\(useCache)")
        return false
    }

    private static func displayParameterService(for profile: AmbilightProfile?) -> io_service_t? {
        let displayID: CGDirectDisplayID?
        if let profile {
            displayID = DisplayCatalog.displayID(for: profile)
        } else {
            displayID = DisplayCatalog.preferredExternalDisplay()?.id ?? CGMainDisplayID()
        }

        guard let displayID else {
            return nil
        }

        let framebuffer = macEvniaCGDisplayIOServicePort(displayID)
        guard framebuffer != 0 else {
            return nil
        }

        let displayService = IODisplayForFramebuffer(framebuffer, 0)
        return displayService != 0 ? displayService : framebuffer
    }

    private static func ddcService(useCache: Bool) -> IOAVServiceRef? {
        lock.lock()
        if useCache, let cachedService {
            lock.unlock()
            return cachedService
        }
        if !useCache {
            cachedService = nil
        }
        lock.unlock()

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let svc = IOIteratorNext(iterator), svc != 0 {
            if isExternal(svc),
               let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc)?.takeRetainedValue() {
                lock.lock()
                cachedService = av
                lock.unlock()
                IOObjectRelease(svc)
                DebugLog.write("Monitor brightness: bound to external DCPAVServiceProxy")
                return av
            }
            IOObjectRelease(svc)
        }
        DebugLog.write("Monitor brightness: no external DCPAVServiceProxy found")
        return nil
    }

    private static func isExternal(_ service: io_service_t) -> Bool {
        guard let raw = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false
        }
        if let str = raw as? String { return str == "External" }
        return false
    }

    private static func formatIOReturn(_ status: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: status))
    }
}
