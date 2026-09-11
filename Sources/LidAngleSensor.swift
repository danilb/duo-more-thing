import Foundation
import AppKit
import IOKit
import IOKit.hid

/// Reads the MacBook's built-in lid angle sensor.
///
/// HID feature report (not an input report):
///   VendorID 0x05AC, ProductID 0x8104, UsagePage 0x20 (Sensor), Usage 0x8A (Orientation)
///   reportID 1 -> 3 bytes [0x01, lo, hi], angle = little-endian UInt16, in degrees.
/// Reverse engineering: github.com/samhenrigold/LidAngleSensor
final class LidAngleSensor {

    private(set) var isAvailable = false
    private(set) var angle: Double = 180

    private var device: IOHIDDevice?
    private var isOpen = false
    private var buffer = [UInt8](repeating: 0, count: 8)

    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    init() {
        discover()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reopen()
            }
        }
    }

    deinit { stop() }

    // MARK: - Device discovery

    private func discover() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else { return }

        // Match the sensor strictly: page 0x20 / usage 0x8A.
        // Other interfaces behind the same pid=0x8104 (page 0xFF00) fail the feature
        // report, and matching page 0x01 would drag in a keystroke-receiving
        // permission prompt.
        let criteria: [[String: Any]] = [
            [kIOHIDPrimaryUsagePageKey as String: 0x20,
             kIOHIDPrimaryUsageKey as String: 0x8A],
            [kIOHIDDeviceUsagePageKey as String: 0x20,
             kIOHIDDeviceUsageKey as String: 0x8A],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }

        for candidate in devices {
            let page = (IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            if page == 0x01 { continue } // just in case: never keyboards or mice
            guard IOHIDDeviceOpen(candidate, Self.noOptions) == kIOReturnSuccess else { continue }
            var probe = [UInt8](repeating: 0, count: 8)
            var length = CFIndex(probe.count)
            let result = IOHIDDeviceGetReport(candidate, kIOHIDReportTypeFeature, 1, &probe, &length)
            IOHIDDeviceClose(candidate, Self.noOptions)
            if result == kIOReturnSuccess && length >= 3 {
                device = candidate
                isAvailable = true
                angle = Double(UInt16(probe[2]) << 8 | UInt16(probe[1]))
                break
            }
        }
    }

    private func reopen() {
        guard isAvailable, let device else { return }
        if isOpen { IOHIDDeviceClose(device, Self.noOptions); isOpen = false }
        if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess { isOpen = true }
    }

    // MARK: - Polling

    func start() {
        guard isAvailable else { return }
        reopen()
    }

    func stop() {
        if isOpen, let device {
            IOHIDDeviceClose(device, Self.noOptions)
            isOpen = false
        }
    }

    /// Current angle in degrees, nil when the device is unavailable.
    @discardableResult
    func read() -> Double? {
        guard isOpen, let device else { return nil }
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length)
        guard result == kIOReturnSuccess, length >= 3 else {
            // The connection can drop after sleep — reopen it.
            isOpen = false
            reopen()
            return nil
        }
        angle = Double(UInt16(buffer[2]) << 8 | UInt16(buffer[1]))
        return angle
    }
}

