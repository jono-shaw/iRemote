import Foundation
import IOKit
import IOKit.hid

enum HIDManagerError: Error {
    case openFailed(IOReturn)
}

struct HIDEvent: CustomStringConvertible {
    enum Kind { case connected, disconnected, button, raw, axis }
    let kind: Kind
    let text: String
    let axisX: Int?
    let axisY: Int?

    init(kind: Kind, text: String, axisX: Int? = nil, axisY: Int? = nil) {
        self.kind = kind
        self.text = text
        self.axisX = axisX
        self.axisY = axisY
    }

    var description: String {
        switch kind {
        case .connected:    return "🔗 \(text)"
        case .disconnected: return "✂️ \(text)"
        case .button:       return "🎛 \(text)"
        case .raw:          return "📦 \(text)"
        case .axis:         return "👆 \(text)"
        }
    }
}

/// Path A foundation: surface every paired Apple-vendor HID device,
/// emit ButtonEvents for parsed HID values, and (for diagnostic builds)
/// dump raw input reports including any custom Report IDs that may
/// carry Opus voice payloads.
final class HIDManager {
    /// Set true to also dump raw input reports (heavy console output).
    /// Phase 2 will flip this on; Phase 1 leaves it off.
    var dumpRawReports: Bool = false

    private let manager: IOHIDManager
    private let onEvent: (HIDEvent) -> Void

    /// Per-device buffers must outlive the device subscription.
    private var perDevice: [DeviceKey: PerDevice] = [:]

    /// Hashable key per device (IOHIDDevice is a CF type, not directly hashable in Swift).
    private struct DeviceKey: Hashable {
        let raw: UnsafeRawPointer
        init(_ device: IOHIDDevice) {
            self.raw = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
        }
    }

    private final class PerDevice {
        let device: IOHIDDevice
        let reportBuffer: UnsafeMutablePointer<UInt8>
        let reportBufferSize: Int
        init(device: IOHIDDevice, bufferSize: Int) {
            self.device = device
            self.reportBufferSize = bufferSize
            self.reportBuffer = .allocate(capacity: bufferSize)
        }
        deinit {
            reportBuffer.deallocate()
        }
    }

    init(onEvent: @escaping (HIDEvent) -> Void) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.onEvent = onEvent
    }

    func start() throws {
        // Match Apple vendor; we filter further inside the matched callback so we
        // also notice unexpected Apple devices instead of silently missing them.
        let matching: [String: Any] = [kIOHIDVendorIDKey: 0x05AC]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDManager>.fromOpaque(ctx).takeUnretainedValue().handleMatched(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDManager>.fromOpaque(ctx).takeUnretainedValue().handleRemoved(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDManagerError.openFailed(result)
        }
    }

    // MARK: - Match / Remove

    private func handleMatched(_ device: IOHIDDevice) {
        let name = stringProp(device, kIOHIDProductKey) ?? "(unknown)"
        let pid = intProp(device, kIOHIDProductIDKey) ?? 0
        let vid = intProp(device, kIOHIDVendorIDKey) ?? 0

        guard isLikelySiriRemote(name: name, pid: pid) else {
            // Helpful for diagnosing matching issues, but quiet on the menu.
            NSLog("HIDManager ignoring non-remote: name=%@ vid=0x%04x pid=0x%04x", name, vid, pid)
            return
        }

        onEvent(HIDEvent(kind: .connected, text: "\(name) (PID=\(hex4(pid)))"))

        let entry = PerDevice(device: device, bufferSize: 512)
        perDevice[DeviceKey(device)] = entry

        // Parsed HID values (Consumer-page buttons, generic-desktop axes).
        IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<HIDManager>.fromOpaque(ctx).takeUnretainedValue().handleValue(value)
        }, Unmanaged.passUnretained(self).toOpaque())

        // Raw input reports (only logged when dumpRawReports is true).
        IOHIDDeviceRegisterInputReportCallback(
            device,
            entry.reportBuffer,
            entry.reportBufferSize,
            { ctx, _, _, type, reportID, report, length in
                guard let ctx else { return }
                Unmanaged<HIDManager>.fromOpaque(ctx).takeUnretainedValue()
                    .handleRawReport(type: type, reportID: reportID, report: report, length: length)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func handleRemoved(_ device: IOHIDDevice) {
        let name = stringProp(device, kIOHIDProductKey) ?? "(unknown)"
        perDevice.removeValue(forKey: DeviceKey(device))
        onEvent(HIDEvent(kind: .disconnected, text: name))
    }

    // MARK: - Events

    private func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        // Generic Desktop X/Y axes carry touchpad position. Surface them as
        // .axis events so the trackpad driver can turn them into cursor
        // movement; the button parser (which ignores them) is untouched.
        if usagePage == 0x01 {
            switch usage {
            case 0x30: // X
                onEvent(HIDEvent(kind: .axis, text: "X=\(intValue)", axisX: Int(intValue), axisY: nil))
                return
            case 0x31: // Y
                onEvent(HIDEvent(kind: .axis, text: "Y=\(intValue)", axisX: nil, axisY: Int(intValue)))
                return
            default:
                break
            }
        }

        guard let parsed = ButtonReportParser.parse(usagePage: usagePage, usage: usage, value: intValue) else {
            return
        }
        onEvent(HIDEvent(kind: .button, text: parsed))
    }

    private func handleRawReport(type: IOHIDReportType, reportID: UInt32, report: UnsafePointer<UInt8>, length: CFIndex) {
        guard dumpRawReports else { return }
        let display = min(length, 24)
        var hex = ""
        for i in 0..<display { hex += String(format: "%02x ", report[i]) }
        if length > display { hex += "…" }
        let typeStr: String
        switch type {
        case kIOHIDReportTypeInput: typeStr = "IN"
        case kIOHIDReportTypeOutput: typeStr = "OUT"
        case kIOHIDReportTypeFeature: typeStr = "FEAT"
        default: typeStr = "?"
        }
        onEvent(HIDEvent(kind: .raw, text: "\(typeStr) ID=\(hex2(reportID)) len=\(length) \(hex)"))
    }

    // MARK: - Helpers

    private func isLikelySiriRemote(name: String, pid: Int) -> Bool {
        // Known Siri Remote PIDs:
        //   0x0265 — 1st gen (Apple TV 4G, 2015) — touchpad + glass face
        //   0x0266 — variant
        //   0x0267 — 2nd gen (2021)
        //   0x026D — A1962 / 1st-gen 2016 refresh observed on this project
        if [0x0265, 0x0266, 0x0267, 0x026D].contains(pid) { return true }
        let lower = name.lowercased()
        return lower.contains("siri remote") || lower.contains("apple tv remote")
    }

    private func stringProp(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func intProp(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private func hex4(_ v: Int) -> String { String(format: "0x%04X", v) }
    private func hex2(_ v: UInt32) -> String { String(format: "0x%02X", v) }
}
