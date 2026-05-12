import Foundation
import IOKit.hid

/// Watches for USB attach/detach of the Philips Evnia LampArray HID so the
/// engine can resume promptly when the monitor (re)appears after sleep, USB
/// reset, or a power cycle — instead of waiting for the fixed retry timer.
final class LampArrayWatcher {
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?

    private let manager: IOHIDManager

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: LampArrayDevice.vendorID,
            kIOHIDProductIDKey: LampArrayDevice.productID,
            kIOHIDDeviceUsagePageKey: LampArrayDevice.usagePage,
            kIOHIDDeviceUsageKey: LampArrayDevice.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<LampArrayWatcher>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onAttach?() }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<LampArrayWatcher>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onDetach?() }
        }, context)

        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
