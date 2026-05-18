import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var remote: RemoteDictationService?
    private var injector: TextInjector?
    private var hidManager: HIDManager?
    private var trackpad: TrackpadDriver?
    private var calibrationController: CalibrationWindowController?
    private var modelManagerController: ModelManagerWindowController?
    private let profileMonitor = ProfileMonitor()
    private var lastUtteranceText: String = "—"
    private var totalUtterances: Int = 0
    private var injectResults = true
    private var listenerRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController()
        self.menuBar = menuBar
        menuBar.appendLog("iRemote v0.6 - Siri Remote mic")
        menuBar.appendLog("log: \(MenuBarController.logFilePath.path)")

        let remote = RemoteDictationService()
        self.remote = remote
        for line in remote.readinessLines {
            menuBar.appendLog(line)
        }
        if let problem = remote.readinessProblem {
            menuBar.appendLog("Needs setup: \(problem)")
            menuBar.appendLog("Small model: \(remote.preferredModelInstallHint)")
            menuBar.setStatus(.problem)
        }

        self.trackpad = TrackpadDriver()

        let injector = TextInjector()
        self.injector = injector
        if injector.hasAccessibility() {
            menuBar.appendLog("Accessibility: ready")
        } else {
            menuBar.appendLog("Accessibility: needed for automatic paste")
            menuBar.appendLog("No Accessibility prompt is shown on launch")
        }

        menuBar.installActions(
            toggleListener: { [weak self] in
                self?.toggleRemoteListener()
            },
            diagnostics: { [weak self] in
                self?.showDiagnostics()
            },
            calibrateTouchpad: { [weak self] in
                self?.showTouchpadCalibration()
            },
            resetCalibration: { [weak self] in
                self?.resetTouchpadCalibration()
            },
            manageModels: { [weak self] in
                self?.showModelManager()
            },
            installProfile: { [weak self] in
                self?.installBluetoothProfile()
            },
            restartApp: { [weak self] in
                self?.restartApp()
            }
        )

        // Profile monitor: surfaces a coloured Bluetooth-access row
        // in the menu. Two signals feed it — the authoritative helper
        // `profile-status` command and the behavioural pklg-growth
        // event stream. The helper is the source of truth when
        // available; behavioural is the fallback for users who haven't
        // yet approved helper installation.
        profileMonitor.onStatusChange = { [weak self] status in
            self?.menuBar?.setProfileStatus(status)
        }
        profileMonitor.helperStatusProvider = { [weak remote] in
            await remote?.helperProfileStatus() ?? .unknown
        }
        profileMonitor.start()
        menuBar.setProfileStatus(profileMonitor.status)
        menuBar.setMode("Live")
        menuBar.setInjectionEnabled(injectResults)

        if remote.readinessProblem == nil {
            startRemoteListener()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRemoteListener()
    }

    private func toggleRemoteListener() {
        if listenerRunning {
            stopRemoteListener()
        } else {
            startRemoteListener()
        }
    }

    private func startRemoteListener() {
        guard !listenerRunning else {
            menuBar?.appendLog("Remote mic listener already running")
            return
        }
        guard let remote else { return }

        menuBar?.setStatus(.starting)
        menuBar?.appendLog("Starting Remote mic packet capture")
        menuBar?.appendLog("Admin permission is only used if the helper is missing")
        profileMonitor.listenerIsActive = true
        startRemoteButtonDiagnostics()
        remote.startContinuousListening { [weak self] event in
            // We're already on the main thread because RemoteDictationService
            // dispatches every callback via RunLoop.main.perform with all
            // runloop modes. Hopping through Task { @MainActor in ... } here
            // would re-queue the event on the default-mode dispatch queue
            // and stall it while NSMenu is in modal tracking — that was the
            // MENU-doesn't-close bug. Call synchronously instead.
            MainActor.assumeIsolated {
                self?.handleRemoteEvent(event)
            }
        }
    }

    private func stopRemoteListener() {
        listenerRunning = false
        remote?.stopContinuousListening()
        menuBar?.setMode("Off")
        menuBar?.setStatus(.stopped)
        menuBar?.appendLog("Remote mic listener paused")
        profileMonitor.listenerIsActive = false
    }


    private func startRemoteButtonDiagnostics() {
        guard hidManager == nil else { return }
        do {
            let manager = HIDManager { [weak self] event in
                Task { @MainActor in
                    self?.handleHIDEvent(event)
                }
            }
            try manager.start()
            hidManager = manager
            menuBar?.appendLog("Remote button diagnostics: on")
        } catch {
            menuBar?.appendLog("Remote button diagnostics unavailable: \(error.localizedDescription)")
        }
    }

    private func handleHIDEvent(_ event: HIDEvent) {
        switch event.kind {
        case .connected, .disconnected:
            menuBar?.appendLog("Remote HID: \(event.text)")
        case .button:
            handleRemoteButton(event.text)
        case .axis:
            // The Siri Remote 1st gen does not surface touchpad axes through
            // IOHIDManager — those arrive via BLE handle 0x0023 instead, see
            // handleTouchpadSample. Future remote variants might wire HID
            // axes, so we just ignore them here without crashing.
            break
        case .raw:
            break
        }
    }

    private func handleRemoteButton(_ text: String) {
        menuBar?.appendLog("Remote button: \(text)")

        // The Siri/mic button comes through the macOS HID stack on this
        // remote — the MENU button and touchpad do NOT (see
        // handleRemoteBLEButton / handleTouchpadSample for those paths).
        guard text.hasPrefix("Search/Siri") else { return }

        if text.contains("↓") {
            let hasFrames = remote?.setRemoteMicButtonDown(true) ?? false
            if listenerRunning || hasFrames {
                menuBar?.setStatus(.recording)
            }
        } else if text.contains("↑") {
            let hasFrames = remote?.setRemoteMicButtonDown(false) ?? false
            if listenerRunning && !hasFrames {
                menuBar?.setStatus(.listening)
            }
        }
    }

    /// Button bitmap decoded from BLE handle 0x0023 (2-byte reports).
    /// Byte 1 of the report is a bitmap of which buttons are *currently*
    /// held down: 0x20 is the MENU bit; 0x00 means "no buttons". Releases
    /// of *any* button produce 0x00, so toggling on 0x00 alone would
    /// (incorrectly) trigger on every button release. We track the last
    /// non-zero press and act on the 0x00 release only if the MENU bit
    /// was part of that press.
    private var lastBLEButtonPress: UInt8 = 0

    private func handleRemoteBLEButton(code: UInt8) {
        if code == 0x00 {
            let released = lastBLEButtonPress
            lastBLEButtonPress = 0
            // Strict equality — not a bitmask check. Other buttons emit
            // their own non-zero codes and we must NOT treat their
            // release as a MENU release just because some bit happens
            // to alias 0x20. Touchpad clicks come through the touchpad
            // sample stream (byte 1 = 0x80), not the button stream.
            if released == 0x20 {
                menuBar?.toggleMenu()
            }
        } else {
            lastBLEButtonPress = code
            menuBar?.appendLog(String(format: "Remote BLE button pressed: 0x%02X", code))
        }
    }

    private func handleTouchpadSample(_ sample: RemoteTouchpadSample) {
        // While the calibration window is up, divert samples to it so
        // the trackpad doesn't move the focus dot during recording.
        if let cal = calibrationController, cal.isActive {
            cal.handleSample(sample)
            return
        }
        trackpad?.onSample(sample)
    }

    private func showTouchpadCalibration() {
        if let existing = calibrationController, let win = existing.window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = CalibrationWindowController()
        calibrationController = controller
        controller.onComplete = { [weak self] calibration in
            guard let self else { return }
            if let calibration {
                self.trackpad?.applyCalibration(calibration)
                self.menuBar?.appendLog("Touchpad calibration saved.")
            } else {
                self.menuBar?.appendLog("Touchpad calibration cancelled.")
            }
            // Clear the reference once the window closes so the next
            // invocation starts a fresh flow.
            DispatchQueue.main.async { [weak self] in
                if self?.calibrationController === controller,
                   self?.calibrationController?.window?.isVisible == false {
                    self?.calibrationController = nil
                }
            }
        }
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resetTouchpadCalibration() {
        TouchpadCalibration.resetDefaults()
        trackpad?.applyCalibration(.identity)
        menuBar?.appendLog("Touchpad calibration reset to identity.")
    }

    /// Triggered from the menu's "Install Bluetooth Profile…" row
    /// when `ProfileMonitor` reports `captureStalled`. Opens Apple's
    /// official profile-distribution page in the default browser;
    /// the user signs in with their Apple ID, downloads the
    /// Bluetooth Logging Profile from there, and approves the
    /// install in System Settings → Privacy & Security → Profiles.
    ///
    /// iRemote intentionally does NOT bundle the profile itself:
    /// the file Apple ships is marked "Apple Confidential — do not
    /// distribute", so redistributing it would be a copyright
    /// violation. Pointing the user at Apple's own URL is the only
    /// way to make this affordance available in an open-source
    /// build.
    private static let bluetoothProfileURL = URL(string: "https://developer.apple.com/services-account/download?path=/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig")!

    private func installBluetoothProfile() {
        NSWorkspace.shared.open(Self.bluetoothProfileURL)
        menuBar?.appendLog("Opening Apple's profile download in your browser. Sign in with your Apple ID, then approve the install in System Settings → Privacy & Security → Profiles.")
        // Tightly poll the helper for the next ~30 s so we notice
        // the install as soon as the user approves it, rather than
        // waiting for the regular 6 s background tick.
        scheduleAggressiveProfilePoll(rounds: 12, interval: 2.5)
    }

    /// Drives `ProfileMonitor.pokeHelperPoll()` on a tight schedule
    /// after the user is sent to System Settings to install the
    /// profile. The regular background poll (every 6 s) still runs;
    /// this just shortens the time-to-detect right when it matters
    /// most.
    private func scheduleAggressiveProfilePoll(rounds: Int, interval: TimeInterval) {
        guard rounds > 0 else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<rounds {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.profileMonitor.pokeHelperPoll()
            }
        }
    }

    /// Quits the current app instance and re-launches it from disk.
    /// Used to recover from the `.needsRestart` state — once the
    /// Bluetooth profile is installed mid-session, PacketLogger needs
    /// to be re-spawned with the new entitlement before it'll start
    /// receiving HCI bytes.
    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func showModelManager() {
        if let existing = modelManagerController, let win = existing.window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ModelManagerWindowController()
        modelManagerController = controller
        controller.onActiveModelChanged = { [weak self] filename in
            self?.remote?.setActiveModel(filename: filename)
            self?.menuBar?.appendLog("Whisper model switched to \(filename)")
        }
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleRemoteEvent(_ event: RemoteListenerEvent) {
        switch event {
        case .listening(let message):
            listenerRunning = true
            menuBar?.setMode("Live")
            menuBar?.setStatus(.listening)
            menuBar?.appendLog(message)
            menuBar?.appendLog("Hold Siri/mic anytime; speech frames trigger recording")

        case .captureActive(let byteCount):
            profileMonitor.noteCaptureActive(byteCount: byteCount)
            menuBar?.appendLog("Bluetooth capture active: \(byteCount / 1024) KB")

        case .recording:
            menuBar?.setStatus(.recording)
            menuBar?.appendLog("Remote mic started")

        case .transcribing:
            menuBar?.setStatus(.transcribing)
            menuBar?.appendLog("Remote mic stopped; transcribing")

        case .result(let result):
            handleRemoteResult(result)

        case .failed(let message):
            listenerRunning = false
            menuBar?.setStatus(.problem)
            menuBar?.appendLog("Remote listener failed: \(message)")

        case .stopped:
            listenerRunning = false
            menuBar?.setMode("Off")
            menuBar?.setStatus(.stopped)
            menuBar?.appendLog("Remote mic listener paused")

        case .remoteButton(let code):
            handleRemoteBLEButton(code: code)

        case .touchpadSample(let sample):
            handleTouchpadSample(sample)
        }
    }

    private func handleRemoteResult(_ result: RemoteDictationResult) {
        totalUtterances += 1
        lastUtteranceText = result.transcript
        menuBar?.appendLog("Remote → \"\(result.transcript)\"")
        if let wavPath = result.wavPath {
            menuBar?.appendLog("Raw WAV: \(wavPath)")
        }
        if let processedWavPath = result.processedWavPath {
            menuBar?.appendLog("Voice WAV: \(processedWavPath)")
        }
        if result.opusFrameCount > 0 {
            menuBar?.appendLog("Opus frames: \(result.opusFrameCount)")
        }
        if injectResults {
            if injector?.hasAccessibility() == true {
                if injector?.inject(result.transcript + " ") == true {
                    menuBar?.appendLog("Pasted into focused app")
                } else {
                    menuBar?.appendLog("Paste failed; transcript is in the log")
                }
            } else {
                injector?.requestAccessibility()
                menuBar?.appendLog("Accessibility permission needed before automatic paste")
            }
        }
        menuBar?.setStatus(listenerRunning ? .listening : .standby)
    }

    private func toggleInjection() {
        if !injectResults, injector?.hasAccessibility() != true {
            injector?.requestAccessibility()
            menuBar?.appendLog("Accessibility permission is needed before typing can turn on")
            return
        }
        injectResults.toggle()
        menuBar?.setInjectionEnabled(injectResults)
        menuBar?.appendLog("Typing after recognition: \(injectResults ? "on" : "off")")
    }

    private func showDiagnostics() {
        menuBar?.appendLog("listener: \(listenerRunning ? "running" : "paused")")
        menuBar?.appendLog("utterances: \(totalUtterances)")
        menuBar?.appendLog("last: \(lastUtteranceText)")
        remote?.readinessLines.forEach { menuBar?.appendLog($0) }
        if let remote, URL(fileURLWithPath: remote.whisperModelPath).lastPathComponent != "ggml-small.bin" {
            menuBar?.appendLog("Small model: \(remote.preferredModelInstallHint)")
        }
        menuBar?.revealLogFile()
    }
}
