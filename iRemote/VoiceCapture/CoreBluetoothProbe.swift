import Foundation
import CoreBluetooth

/// Phase 2b diagnostic: discover which services/characteristics on the
/// already-paired Siri Remote are actually visible to a third-party app via
/// CoreBluetooth, despite macOS hiding the HID UUID (0x1812).
///
/// Logs every step so we can see, in order:
///   1. CB authorization state.
///   2. Already-connected peripherals matching known service UUIDs.
///   3. All services discovered for the chosen peripheral.
///   4. All characteristics + their property bitmasks.
///   5. Live notification payloads (size + first bytes) — pressing buttons
///      and holding the Siri button while speaking should emit data here
///      if any non-HID path exists.
final class CoreBluetoothProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private let log: (String) -> Void
    private var central: CBCentralManager!
    private var target: CBPeripheral?

    /// Names we expect to match the user's paired remote.
    private let nameFragments = ["iRemote", "Apple TV Remote", "Siri Remote"]

    /// Service UUIDs the device is known/likely to advertise.
    /// HID (0x1812) is included for diagnostic: macOS will strip it out
    /// of the result, which is itself useful info to log.
    private let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1812"),                                   // HID (will be filtered by macOS)
        CBUUID(string: "180F"),                                   // Battery
        CBUUID(string: "180A"),                                   // Device Information
        CBUUID(string: "1800"),                                   // Generic Access
        CBUUID(string: "1801"),                                   // Generic Attribute
        CBUUID(string: "8341F2B4-C013-4F04-8197-C4CDB42E26DC"),   // Apple proprietary (Siri Remote)
    ]

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
        let queue = DispatchQueue(label: "iRemote.CoreBluetoothProbe")
        self.central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("CB state: poweredOn")
            tryConnectKnownDevice()
        case .poweredOff:
            log("CB state: poweredOff — turn Bluetooth on")
        case .resetting:
            log("CB state: resetting")
        case .unauthorized:
            log("CB state: UNAUTHORIZED — System Settings › Privacy & Security › Bluetooth, enable iRemote.app")
        case .unsupported:
            log("CB state: unsupported (no BLE chip?)")
        case .unknown:
            log("CB state: unknown")
        @unknown default:
            log("CB state: ?")
        }
    }

    private func tryConnectKnownDevice() {
        // First, ask macOS for already-connected peripherals exposing any known service.
        let connected = central.retrieveConnectedPeripherals(withServices: knownServiceUUIDs)
        log("retrieveConnectedPeripherals → \(connected.count) match(es) for known UUIDs")
        for p in connected {
            log("   · \(p.name ?? "(unnamed)")  id=\(p.identifier)")
        }

        let target = connected.first { p in
            guard let n = p.name else { return false }
            return nameFragments.contains(where: n.localizedCaseInsensitiveContains)
        } ?? connected.first

        if let target {
            self.target = target
            target.delegate = self
            log("Connecting to: \(target.name ?? "?")  id=\(target.identifier)")
            central.connect(target, options: nil)
        } else {
            log("No connected match — scanning (10s)…")
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
            ])
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.central.stopScan()
                self?.log("scan timed out (no peripheral matched our name fragments)")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(unnamed)"
        let advUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        log("scan: \(name)  RSSI=\(RSSI)  advServices=\(advUUIDs.map { $0.uuidString })")

        let matchesName = nameFragments.contains { name.localizedCaseInsensitiveContains($0) }
        let matchesUUID = advUUIDs.contains { knownServiceUUIDs.contains($0) }
        guard matchesName || matchesUUID else { return }

        central.stopScan()
        self.target = peripheral
        peripheral.delegate = self
        log("Connecting to scanned: \(name)")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("✓ connected: \(peripheral.name ?? "?")")
        peripheral.discoverServices(nil)   // nil = all visible
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("✗ FailedToConnect: \(error?.localizedDescription ?? "(no err)")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("✂ disconnected: \(error?.localizedDescription ?? "(clean)") — re-scheduling reconnect")
        // Auto-reconnect to keep the diagnostic running
        central.connect(peripheral, options: nil)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let err = error { log("discoverServices error: \(err)"); return }
        let services = peripheral.services ?? []
        log("services (\(services.count)):")
        for s in services {
            log("  service \(s.uuid)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
        if services.isEmpty {
            log("  (zero services exposed — CoreBluetooth has filtered everything)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let err = error { log("discoverCharacteristics error for \(service.uuid): \(err)"); return }
        let chars = service.characteristics ?? []
        log("  → \(chars.count) char(s) under \(service.uuid):")
        for c in chars {
            log(String(format: "    char %@  props=0x%02X (%@)",
                       c.uuid.uuidString,
                       c.properties.rawValue,
                       describe(c.properties)))
            peripheral.discoverDescriptors(for: c)
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard let descs = characteristic.descriptors, !descs.isEmpty else { return }
        for d in descs {
            log("      descriptor \(d.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            log("  notify subscribe FAILED \(characteristic.uuid): \(err)")
        } else {
            log("  notify ON: \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error { log("update error \(characteristic.uuid): \(err)"); return }
        guard let data = characteristic.value, !data.isEmpty else { return }
        let displayLen = min(data.count, 32)
        var hex = ""
        for i in 0..<displayLen { hex += String(format: "%02x ", data[i]) }
        if data.count > displayLen { hex += "…" }
        log("📥 \(characteristic.uuid) len=\(data.count)  \(hex)")
    }

    // MARK: - Helpers

    private func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read)              { parts.append("R") }
        if p.contains(.write)             { parts.append("W") }
        if p.contains(.writeWithoutResponse) { parts.append("Wnr") }
        if p.contains(.notify)            { parts.append("Notify") }
        if p.contains(.indicate)          { parts.append("Indicate") }
        if p.contains(.authenticatedSignedWrites) { parts.append("AuthW") }
        if p.contains(.broadcast)         { parts.append("Bcast") }
        if p.contains(.extendedProperties){ parts.append("Ext") }
        return parts.joined(separator: "|")
    }
}
