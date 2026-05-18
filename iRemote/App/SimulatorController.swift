import Foundation

/// Manages the headless tvOS Simulator that hosts iRemoteTV.app (our audio
/// bridge). Boots it on iRemote.app launch, shuts it down on quit. The
/// simulator runs without any UI window — `xcrun simctl boot` doesn't open
/// Simulator.app, the device runs as background launchd processes.
final class SimulatorController {
    /// Name of the simulator device we'll use. Created if missing.
    let deviceName: String
    /// Bundle ID of the tvOS bridge app (must match what you build/install).
    let bundleID: String
    /// Device type identifier, e.g. "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
    let deviceTypeID: String?
    /// Runtime identifier, e.g. "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"
    let runtimeID: String?

    init(deviceName: String = "iRemoteTV-runtime",
         bundleID: String = "com.iremote.iRemoteTV",
         deviceTypeID: String? = nil,
         runtimeID: String? = nil) {
        self.deviceName = deviceName
        self.bundleID = bundleID
        self.deviceTypeID = deviceTypeID
        self.runtimeID = runtimeID
    }

    /// Locate or create the device, boot it, launch the app.
    func bootAndLaunch(log: (String) -> Void = { print($0) }) {
        guard let udid = findDeviceUDID() ?? createDevice(log: log) else {
            log("[sim] could not find or create device '\(deviceName)'")
            return
        }
        let state = deviceState(udid: udid)
        log("[sim] device \(deviceName) udid=\(udid) state=\(state)")
        if state.lowercased() != "booted" {
            log("[sim] booting…")
            run("xcrun", ["simctl", "boot", udid])
        }
        log("[sim] launching \(bundleID)")
        run("xcrun", ["simctl", "launch", udid, bundleID])
    }

    func shutdown(log: (String) -> Void = { print($0) }) {
        guard let udid = findDeviceUDID() else { return }
        log("[sim] shutting down \(udid)")
        run("xcrun", ["simctl", "shutdown", udid])
    }

    // MARK: - Helpers

    private func findDeviceUDID() -> String? {
        guard let json = runCapture("xcrun", ["simctl", "list", "devices", "--json"]),
              let data = json.data(using: .utf8),
              let plist = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = plist["devices"] as? [String: [[String: Any]]]
        else { return nil }
        for (_, deviceList) in devices {
            for d in deviceList {
                if let name = d["name"] as? String, name == deviceName,
                   let udid = d["udid"] as? String {
                    return udid
                }
            }
        }
        return nil
    }

    private func createDevice(log: (String) -> Void) -> String? {
        let dt = deviceTypeID ?? defaultTVDeviceType()
        let rt = runtimeID ?? defaultTVRuntime()
        guard let dt = dt, let rt = rt else {
            log("[sim] cannot resolve device type / runtime — please install tvOS sim runtime via Xcode")
            return nil
        }
        log("[sim] creating device \(deviceName) (\(dt) / \(rt))")
        let udid = runCapture("xcrun", ["simctl", "create", deviceName, dt, rt])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (udid?.isEmpty == false) ? udid : nil
    }

    private func defaultTVDeviceType() -> String? {
        guard let s = runCapture("xcrun", ["simctl", "list", "devicetypes"]) else { return nil }
        // Parse a line like "Apple TV 4K (3rd generation) (com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p)"
        for line in s.split(separator: "\n") {
            if line.contains("Apple TV"), let open = line.range(of: "(com.apple"), let close = line.range(of: ")", range: open.upperBound..<line.endIndex) {
                return String(line[open.lowerBound..<close.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        }
        return nil
    }

    private func defaultTVRuntime() -> String? {
        guard let s = runCapture("xcrun", ["simctl", "list", "runtimes"]) else { return nil }
        for line in s.split(separator: "\n") where line.contains("tvOS") {
            if let open = line.range(of: "(com.apple"), let close = line.range(of: ")", range: open.upperBound..<line.endIndex) {
                return String(line[open.lowerBound..<close.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        }
        return nil
    }

    private func deviceState(udid: String) -> String {
        let s = runCapture("xcrun", ["simctl", "list", "devices"]) ?? ""
        for line in s.split(separator: "\n") where line.contains(udid) {
            if line.contains("Booted") { return "Booted" }
            if line.contains("Shutdown") { return "Shutdown" }
        }
        return "Unknown"
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [exe] + args
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    private func runCapture(_ exe: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [exe] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
