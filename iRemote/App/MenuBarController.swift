import AppKit
import QuartzCore

/// Wraps a closure as an @objc-callable target so menu items without
/// dedicated NSObject targets can fire arbitrary Swift code.
final class ClosureTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    enum Status {
        case starting
        case standby
        case listening
        case recording
        case transcribing
        case stopped
        case problem
    }

    static let logFilePath: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("iRemote-probe.log")

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var logLines: [String] = []
    private var status: Status = .standby
    private var modeLabel: String = "Remote"
    private var injectionEnabled = true
    private var menuIsOpen = false
    private let logFileHandle: FileHandle?
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var listenerToggleAction: (() -> Void)?
    private var diagnosticsAction: (() -> Void)?
    private var calibrateTouchpadAction: (() -> Void)?
    private var resetCalibrationAction: (() -> Void)?
    private var manageModelsAction: (() -> Void)?
    private var installProfileAction: (() -> Void)?
    private var restartAppAction: (() -> Void)?
    private var profileStatus: ProfileMonitor.Status = .listenerStopped
    private let statusGlyphView = StatusGlyphView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    /// Kept across rebuilds so `menu(_:willHighlight:)` can morph the
    /// Bluetooth Access row in-place between its default state-display
    /// and the "Install Bluetooth Profile…" affordance when the user
    /// hovers it.
    private weak var bluetoothAccessMenuItem: NSMenuItem?

    override init() {
        try? FileManager.default.removeItem(at: Self.logFilePath)
        FileManager.default.createFile(atPath: Self.logFilePath.path, contents: nil)
        self.logFileHandle = try? FileHandle(forWritingTo: Self.logFilePath)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        installStatusGlyphView()
        updateStatusButton()
        statusItem.menu = menu
        // Disable AppKit's responder-chain-driven enable/disable
        // pass so the menu uses each item's explicit `isEnabled`
        // flag directly. Lets us guarantee that informational rows
        // (Status, BLE-when-not-stalled) stay disabled — which is
        // how AppKit natively suppresses the hover highlight — while
        // their `attributedTitle` keeps the text rendered in
        // `labelColor` instead of the dimmed grey AppKit would
        // otherwise paint on disabled rows.
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildMenu()
    }

    /// Programmatically open or close the menu — used by the Siri Remote
    /// MENU button. Tracks `menuIsOpen` via NSMenuDelegate callbacks so
    /// the second press closes rather than re-opening. The BLE button
    /// dispatch path uses RunLoop.main.perform(inModes:) with
    /// eventTracking listed, so this method runs even while NSMenu's
    /// modal tracking owns the main runloop.
    func toggleMenu() {
        if menuIsOpen {
            menu.cancelTracking()
            menuIsOpen = false       // optimistic; delegate confirms
        } else {
            menuIsOpen = true        // optimistic; delegate confirms
            statusItem.button?.performClick(nil)
        }
    }

    // MARK: NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.menuIsOpen = true
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.menuIsOpen = false
            // Reset the Bluetooth Access row to its base appearance
            // so a future open doesn't start with a stale hover
            // morph (the highlight clears, but the title/image
            // we set in willHighlight stay until we revert).
            self.resetBluetoothAccessRowAppearance()
        }
    }

    /// Drives the "hover Bluetooth Access → swap to Install Bluetooth
    /// Profile…" affordance. AppKit fires this delegate hook on every
    /// hover transition during menu tracking, including with `nil` when
    /// the user moves out of the menu entirely; we use that to revert.
    nonisolated func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        MainActor.assumeIsolated {
            self.applyBluetoothHoverMorph(highlightedItem: item)
        }
    }

    private func applyBluetoothHoverMorph(highlightedItem: NSMenuItem?) {
        guard let bleItem = bluetoothAccessMenuItem else { return }
        // Only the captureStalled state is clickable/hoverable. In
        // every other state the BLE row is disabled and AppKit
        // won't highlight it anyway, but the willHighlight delegate
        // hook can still fire (e.g. for arrow-key navigation), so
        // we gate the morph here too.
        guard profileStatus == .captureStalled else { return }

        if highlightedItem === bleItem {
            bleItem.image = menuSymbolImage("square.and.arrow.down")
            bleItem.attributedTitle = nil
            bleItem.title = "Install Bluetooth Profile…"
        } else {
            bleItem.image = profileSymbol(for: profileStatus)
            bleItem.attributedTitle = nil
            bleItem.title = profileStatus.menuText
        }
    }

    private func resetBluetoothAccessRowAppearance() {
        guard let bleItem = bluetoothAccessMenuItem else { return }
        bleItem.image = profileSymbol(for: profileStatus)
        if profileStatus == .captureStalled {
            bleItem.attributedTitle = nil
            bleItem.title = profileStatus.menuText
        } else {
            bleItem.title = ""
            bleItem.attributedTitle = informationalTitle(profileStatus.menuText)
        }
    }

    /// Title attributes for a disabled informational row. Forcing
    /// `.labelColor` explicitly keeps the text rendered at full
    /// strength even when AppKit would otherwise apply its
    /// disabled-item dimming pass; the system menu font matches
    /// the metrics of every other (native) row.
    private func informationalTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 0),
        ])
    }

    func installActions(
        toggleListener: @escaping () -> Void,
        diagnostics: @escaping () -> Void,
        calibrateTouchpad: (() -> Void)? = nil,
        resetCalibration: (() -> Void)? = nil,
        manageModels: (() -> Void)? = nil,
        installProfile: (() -> Void)? = nil,
        restartApp: (() -> Void)? = nil
    ) {
        listenerToggleAction = toggleListener
        diagnosticsAction = diagnostics
        calibrateTouchpadAction = calibrateTouchpad
        resetCalibrationAction = resetCalibration
        manageModelsAction = manageModels
        installProfileAction = installProfile
        restartAppAction = restartApp
        rebuildMenu()
    }

    /// Live Bluetooth-access status indicator, driven by
    /// `ProfileMonitor` in `AppDelegate`. Rebuilds the menu so the
    /// coloured icon and label refresh whenever the status changes,
    /// and refreshes the menu-bar glyph because the warning overlay
    /// depends on the profile state.
    func setProfileStatus(_ status: ProfileMonitor.Status) {
        guard profileStatus != status else { return }
        profileStatus = status
        updateStatusButton()
        rebuildMenu()
    }

    func setStatus(_ status: Status) {
        guard self.status != status else {
            updateStatusButton()
            rebuildMenu()
            return
        }
        self.status = status
        updateStatusButton()
        rebuildMenu()
    }

    func setMode(_ label: String) {
        self.modeLabel = label
        updateStatusButton()
        rebuildMenu()
    }

    func setInjectionEnabled(_ enabled: Bool) {
        self.injectionEnabled = enabled
        rebuildMenu()
    }

    nonisolated func appendLog(_ line: String) {
        Task { @MainActor in self.appendOnMain(line) }
    }

    private func appendOnMain(_ line: String) {
        let stamped = "\(timeFormatter.string(from: Date()))  \(line)"
        logLines.append(stamped)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }

        if let h = logFileHandle, let data = (stamped + "\n").data(using: .utf8) {
            try? h.write(contentsOf: data)
        }
    }

    private func installStatusGlyphView() {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.squareLength
        button.image = nil
        button.imagePosition = .noImage
        button.title = ""

        statusGlyphView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusGlyphView)
        NSLayoutConstraint.activate([
            statusGlyphView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            statusGlyphView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            statusGlyphView.widthAnchor.constraint(equalToConstant: 22),
            statusGlyphView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func updateStatusButton() {
        let presentation = statusPresentation
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.title = ""
        statusItem.button?.toolTip = menuBarToolTip
        // When the profile state is calling for user attention
        // (setup needed or app restart needed), the menu-bar glyph
        // becomes a yellow warning so the user can see something is
        // wrong without opening the menu. Listener-status glyph
        // resumes once the profile state clears.
        if let overlay = menuBarWarning {
            statusGlyphView.setStatus(.problem, symbolName: overlay.symbol, description: overlay.tooltip)
        } else {
            statusGlyphView.setStatus(status, symbolName: presentation.symbol, description: presentation.text)
        }
    }

    /// When the profile state needs the user's attention, the menu
    /// bar glyph should reflect that — otherwise the user could be
    /// listening for the remote with no idea the underlying capture
    /// is broken. Returns a yellow warning symbol when the profile
    /// is missing or needs the app to restart; `nil` in all healthy
    /// states (so the regular listener glyph stays visible).
    private var menuBarWarning: (symbol: String, tooltip: String)? {
        switch profileStatus {
        case .captureStalled:
            return ("exclamationmark.triangle.fill",
                    "iRemote: Bluetooth Access needs setup")
        case .needsRestart:
            return ("exclamationmark.triangle.fill",
                    "iRemote: restart required to finish Bluetooth setup")
        case .listenerStopped, .starting, .captureActive:
            return nil
        }
    }

    private var menuBarToolTip: String {
        if let overlay = menuBarWarning { return overlay.tooltip }
        return "iRemote: " + statusPresentation.text
    }

    private var statusText: String { statusPresentation.text }

    private var statusPresentation: (symbol: String, text: String) {
        switch status {
        case .starting:
            return ("arrow.triangle.2.circlepath", "Starting")
        case .standby:
            return ("circle.dotted", "Standby")
        case .listening:
            return ("dot.radiowaves.left.and.right", "Listening")
        case .recording:
            return ("waveform", "Recording")
        case .transcribing:
            return ("sparkle.magnifyingglass", "Transcribing")
        case .stopped:
            return ("pause.circle.fill", "Off")
        case .problem:
            return ("exclamationmark.triangle.fill", "Needs attention")
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        bluetoothAccessMenuItem = nil

        // Status row — informational, never clickable. Native
        // AppKit's mechanism for "no hover highlight, no click" is
        // a disabled item. With `menu.autoenablesItems = false` and
        // `isEnabled = false`, the row picks up no hover styling.
        // We pair that with `attributedTitle` carrying an explicit
        // `.labelColor` foreground so AppKit's disabled-item
        // dimming pass doesn't wash the text out — that was the
        // grey-text complaint that originally pushed us to the
        // (alignment-flawed) custom-view path. The image is a
        // non-template palette symbol, so it stays vibrant too.
        let statusItem = NSMenuItem(title: "Status: \(statusText)", action: nil, keyEquivalent: "")
        statusItem.image = menuSymbolImage(statusPresentation.symbol)
        statusItem.attributedTitle = informationalTitle("Status: \(statusText)")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Bluetooth Access row — clickable + hoverable ONLY when
        // `profileStatus == .captureStalled`. In every other state
        // it's purely informational (no action, no hover).
        //
        // When stalled: native NSMenuItem with an action target.
        // AppKit handles the hover highlight + colour inversion;
        // `menu(_:willHighlight:)` swaps the icon/title in-place
        // to the install affordance while highlighted.
        //
        // When not stalled: same isEnabled=false + attributedTitle
        // pattern as the Status row.
        let profileItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        profileItem.image = profileSymbol(for: profileStatus)
        if profileStatus == .captureStalled, installProfileAction != nil {
            profileItem.title = profileStatus.menuText
            let bleTarget = ClosureTarget { [weak self] in
                self?.installProfileAction?()
            }
            profileItem.target = bleTarget
            profileItem.action = #selector(ClosureTarget.invoke)
            profileItem.representedObject = bleTarget
            profileItem.isEnabled = true
        } else {
            profileItem.attributedTitle = informationalTitle(profileStatus.menuText)
            profileItem.isEnabled = false
        }
        menu.addItem(profileItem)
        bluetoothAccessMenuItem = profileItem

        // Restart affordance: when the profile was installed mid-session
        // PacketLogger needs to be re-spawned with the new entitlement,
        // which only happens on a fresh app launch. Offer a one-click
        // restart so the user doesn't have to find the Quit item and
        // re-open from Spotlight.
        if profileStatus == .needsRestart, let restart = restartAppAction {
            let item = NSMenuItem(
                title: "Restart iRemote",
                action: #selector(ClosureTarget.invoke),
                keyEquivalent: ""
            )
            item.image = menuSymbolImage("arrow.clockwise.circle.fill")
            let target = ClosureTarget { restart() }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Start / Pause Listener
        let listenerItem = NSMenuItem(
            title: listenerActionTitle,
            action: #selector(ClosureTarget.invoke),
            keyEquivalent: ""
        )
        listenerItem.image = menuSymbolImage(listenerActionSymbol)
        let listenerTarget = ClosureTarget { [weak self] in self?.listenerToggleAction?() }
        listenerItem.target = listenerTarget
        listenerItem.representedObject = listenerTarget
        listenerItem.isEnabled = (status != .starting) && (listenerToggleAction != nil)
        menu.addItem(listenerItem)

        menu.addItem(.separator())

        // Show Diagnostics
        let diagItem = NSMenuItem(
            title: "Show Diagnostics",
            action: #selector(ClosureTarget.invoke),
            keyEquivalent: ""
        )
        diagItem.image = menuSymbolImage("stethoscope")
        let diagTarget = ClosureTarget { [weak self] in self?.diagnosticsAction?() }
        diagItem.target = diagTarget
        diagItem.representedObject = diagTarget
        diagItem.isEnabled = diagnosticsAction != nil
        menu.addItem(diagItem)

        // Manage Whisper Models…
        if let manage = manageModelsAction {
            let item = NSMenuItem(
                title: "Manage Whisper Models…",
                action: #selector(ClosureTarget.invoke),
                keyEquivalent: ""
            )
            item.image = menuSymbolImage("waveform.badge.magnifyingglass")
            let target = ClosureTarget { manage() }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        if calibrateTouchpadAction != nil || resetCalibrationAction != nil {
            menu.addItem(.separator())
        }

        // Calibrate Touchpad…
        if let calibrate = calibrateTouchpadAction {
            let item = NSMenuItem(
                title: "Calibrate Touchpad…",
                action: #selector(ClosureTarget.invoke),
                keyEquivalent: ""
            )
            item.image = menuSymbolImage("hand.draw")
            let target = ClosureTarget { calibrate() }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        // Reset Touchpad Calibration
        if let reset = resetCalibrationAction {
            let item = NSMenuItem(
                title: "Reset Touchpad Calibration",
                action: #selector(ClosureTarget.invoke),
                keyEquivalent: ""
            )
            item.image = menuSymbolImage("arrow.uturn.backward")
            let target = ClosureTarget { reset() }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit iRemote",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = menuSymbolImage("power")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    private func menuSymbolImage(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        image.isTemplate = true
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
    }

    /// SF Symbol rendered in a fixed colour for the Bluetooth-access
    /// status row. NSMenuItem.image is template-tinted by default;
    /// clearing `isTemplate` plus applying a palette configuration
    /// produces a stable indicator colour regardless of macOS dark
    /// mode.
    ///
    /// Two-layer (`.fill`) symbols need TWO palette colours, not one
    /// — same issue as the Whisper-manager checkmark. Passing a
    /// single tint colours both layers (background fill AND
    /// foreground glyph) the same, making the glyph invisible
    /// against the same-coloured fill (e.g. a green circle with
    /// no visible checkmark, or a yellow triangle with no visible
    /// exclamation mark). Map the known multi-layer icons to
    /// explicit `[foreground, background]` palette pairs.
    private func coloredMenuSymbol(_ name: String, tint: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let palette = paletteColors(for: name, tint: tint)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        let tinted = image.withSymbolConfiguration(config) ?? image
        tinted.isTemplate = false
        return tinted
    }

    /// Per-symbol palette mapping. `[foreground, background]` for
    /// two-layer SF Symbols (`.fill` variants); single-element
    /// fallback for one-layer glyphs that don't need a contrast
    /// foreground.
    private func paletteColors(for symbolName: String, tint: NSColor) -> [NSColor] {
        switch symbolName {
        case "checkmark.circle.fill":
            // White check on tint-coloured circle — same convention
            // as the system "selected" checkmark in macOS Settings.
            return [.white, tint]
        case "exclamationmark.triangle.fill":
            // Black exclamation on tint-coloured triangle — Apple's
            // standard warning idiom (caution-yellow triangle with
            // a dark exclamation glyph for legibility against the
            // bright background).
            return [.black, tint]
        default:
            return [tint]
        }
    }

    /// Picks the right rendering for the Bluetooth-access indicator.
    /// `.starting` / `.listenerStopped` render as the standard
    /// template (so they match surrounding text colour); the binary
    /// success / failure / warning states bake the tint into a
    /// palette-coloured symbol so the green check and yellow warning
    /// stay readable across light/dark mode.
    private func profileSymbol(for status: ProfileMonitor.Status) -> NSImage? {
        switch status {
        case .starting, .listenerStopped:
            return menuSymbolImage(status.symbolName)
        case .captureActive, .captureStalled, .needsRestart:
            return coloredMenuSymbol(status.symbolName, tint: status.tintColor)
        }
    }


    private var listenerActionTitle: String {
        switch status {
        case .starting:
            return "Starting"
        case .listening, .recording, .transcribing:
            return "Pause Listener"
        case .standby, .stopped, .problem:
            return "Start Listener"
        }
    }

    private var listenerActionSymbol: String {
        switch status {
        case .starting:
            return "arrow.triangle.2.circlepath"
        case .listening, .recording, .transcribing:
            return "pause.fill"
        case .standby, .stopped, .problem:
            return "play.fill"
        }
    }

    func revealLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.logFilePath])
    }
}

// MARK: - Animated status glyph

private final class StatusGlyphView: NSView {
    private let staticImageView = NSImageView()
    private let waveContainer = CALayer()
    private let analysisContainer = CALayer()
    private var currentStatus: MenuBarController.Status = .standby
    private var currentSymbolName = "circle.dotted"
    private var currentDescription = "Standby"
    private var waveBars: [CALayer] = []
    private var analysisDots: [CALayer] = []
    private var analysisArc: CAShapeLayer?
    private var analysisRing: CAShapeLayer?
    private var waveConfigured = false
    private var analysisConfigured = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        staticImageView.translatesAutoresizingMaskIntoConstraints = false
        staticImageView.imageScaling = .scaleProportionallyDown
        staticImageView.contentTintColor = .labelColor
        addSubview(staticImageView)
        NSLayoutConstraint.activate([
            staticImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            staticImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            staticImageView.widthAnchor.constraint(equalToConstant: 22),
            staticImageView.heightAnchor.constraint(equalToConstant: 22),
        ])

        waveContainer.masksToBounds = false
        analysisContainer.masksToBounds = false
        layer?.addSublayer(waveContainer)
        layer?.addSublayer(analysisContainer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveContainer.frame = bounds
        analysisContainer.frame = bounds
        layoutWaveBars()
        layoutAnalysisLayers()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        staticImageView.contentTintColor = .labelColor
        refreshLayerColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply animations after view enters the window — Core Animation
        // sometimes drops infinite animations when the layer reattaches.
        switch currentStatus {
        case .recording:
            configureWaveAnimation()
        case .transcribing:
            configureAnalysisAnimation()
        default:
            break
        }
    }

    func setStatus(_ status: MenuBarController.Status, symbolName: String, description: String) {
        let changed = currentStatus != status || currentSymbolName != symbolName
        currentStatus = status
        currentSymbolName = symbolName
        currentDescription = description
        setAccessibilityLabel("iRemote: \(description)")
        toolTip = "iRemote: \(description)"

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch status {
        case .recording where !reduceMotion:
            staticImageView.isHidden = true
            waveContainer.isHidden = false
            analysisContainer.isHidden = true
            if changed || !waveConfigured {
                configureWaveAnimation()
            }
        case .transcribing where !reduceMotion:
            staticImageView.isHidden = true
            waveContainer.isHidden = true
            analysisContainer.isHidden = false
            if changed || !analysisConfigured {
                configureAnalysisAnimation()
            }
        default:
            waveContainer.isHidden = true
            analysisContainer.isHidden = true
            stopWaveAnimation()
            stopAnalysisAnimation()
            staticImageView.isHidden = false
            staticImageView.image = staticSymbolImage(symbolName, description: description)
        }
    }

    private func staticSymbolImage(_ name: String, description: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return nil }
        image.isTemplate = true
        if let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)) {
            configured.isTemplate = true
            return configured
        }
        return image
    }

    // MARK: Recording wave

    private func configureWaveAnimation() {
        waveContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        waveBars.removeAll(keepingCapacity: true)
        waveConfigured = true
        analysisConfigured = false

        let barCount = 5
        for index in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = glyphColor(alpha: 0.96)
            bar.cornerRadius = 1.25
            waveContainer.addSublayer(bar)
            waveBars.append(bar)
        }
        layoutWaveBars()

        let baseTime = waveContainer.convertTime(CACurrentMediaTime(), from: nil)
        let cycleDuration: CFTimeInterval = 1.2
        let waveValuesSteps = 32

        // Sample a smooth sine over `waveValuesSteps` keyframes so the
        // compositor interpolates at display refresh rate instead of jumping
        // between sparse waypoints.
        for (index, bar) in waveBars.enumerated() {
            let phase = Double(index) / Double(barCount) * .pi * 2.0
            var values: [NSNumber] = []
            var keyTimes: [NSNumber] = []
            values.reserveCapacity(waveValuesSteps + 1)
            keyTimes.reserveCapacity(waveValuesSteps + 1)
            for step in 0...waveValuesSteps {
                let t = Double(step) / Double(waveValuesSteps)
                let sinValue = sin(t * .pi * 2.0 + phase)
                // Map [-1,1] → [0.18, 1.0] with extra punch on the peak.
                let normalized = (sinValue + 1.0) / 2.0
                let amp = 0.18 + pow(normalized, 1.35) * 0.82
                values.append(NSNumber(value: amp))
                keyTimes.append(NSNumber(value: t))
            }

            let scale = CAKeyframeAnimation(keyPath: "transform.scale.y")
            scale.values = values
            scale.keyTimes = keyTimes
            scale.duration = cycleDuration
            scale.repeatCount = .infinity
            scale.calculationMode = .cubic
            scale.isRemovedOnCompletion = false
            scale.beginTime = baseTime - Double(index) * 0.08
            bar.add(scale, forKey: "iremote.wave.scale")
        }
    }

    private func stopWaveAnimation() {
        waveContainer.sublayers?.forEach { $0.removeAllAnimations() }
    }

    private func layoutWaveBars() {
        guard !waveBars.isEmpty else { return }
        let barWidth: CGFloat = 2.4
        let gap: CGFloat = 2.2
        let total = CGFloat(waveBars.count) * barWidth + CGFloat(waveBars.count - 1) * gap
        let startX = waveContainer.bounds.midX - total / 2.0
        let maxHeight = max(waveContainer.bounds.height - 2.0, 12.0)
        for (index, bar) in waveBars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: maxHeight)
            bar.position = CGPoint(
                x: startX + CGFloat(index) * (barWidth + gap) + barWidth / 2.0,
                y: waveContainer.bounds.midY
            )
            bar.cornerRadius = barWidth / 2.0
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
    }

    // MARK: Transcribing analysis

    private func configureAnalysisAnimation() {
        analysisContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        analysisDots.removeAll(keepingCapacity: true)
        analysisArc = nil
        analysisRing = nil
        analysisConfigured = true
        waveConfigured = false

        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = glyphColor(alpha: 0.28)
        ring.lineWidth = 1.3
        analysisContainer.addSublayer(ring)
        analysisRing = ring

        let arc = CAShapeLayer()
        arc.fillColor = nil
        arc.strokeColor = glyphColor(alpha: 0.96)
        arc.lineWidth = 1.7
        arc.lineCap = .round
        arc.strokeStart = 0.0
        arc.strokeEnd = 0.32
        analysisContainer.addSublayer(arc)
        analysisArc = arc

        for _ in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = glyphColor(alpha: 0.92)
            dot.cornerRadius = 1.05
            analysisContainer.addSublayer(dot)
            analysisDots.append(dot)
        }
        layoutAnalysisLayers()

        let baseTime = analysisContainer.convertTime(CACurrentMediaTime(), from: nil)

        let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
        rotate.fromValue = 0
        rotate.toValue = CGFloat.pi * 2.0
        rotate.duration = 1.1
        rotate.repeatCount = .infinity
        rotate.timingFunction = CAMediaTimingFunction(name: .linear)
        rotate.isRemovedOnCompletion = false
        arc.add(rotate, forKey: "iremote.analysis.rotate")

        // Sweep the visible arc length subtly to suggest "thinking".
        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweep.values = [0.18, 0.42, 0.32, 0.46, 0.22, 0.18]
        sweep.keyTimes = [0, 0.22, 0.46, 0.68, 0.88, 1.0]
        sweep.duration = 2.2
        sweep.repeatCount = .infinity
        sweep.calculationMode = .cubic
        sweep.isRemovedOnCompletion = false
        arc.add(sweep, forKey: "iremote.analysis.sweep")

        // Three "typing" dots pulsing in sequence below the ring.
        for (index, dot) in analysisDots.enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.22, 0.95, 0.22]
            pulse.keyTimes = [0.0, 0.5, 1.0]
            pulse.duration = 1.05
            pulse.repeatCount = .infinity
            pulse.calculationMode = .cubic
            pulse.isRemovedOnCompletion = false
            pulse.beginTime = baseTime + Double(index) * 0.18
            dot.add(pulse, forKey: "iremote.analysis.dot")

            let bump = CAKeyframeAnimation(keyPath: "transform.scale")
            bump.values = [0.78, 1.18, 0.78]
            bump.keyTimes = [0.0, 0.5, 1.0]
            bump.duration = 1.05
            bump.repeatCount = .infinity
            bump.calculationMode = .cubic
            bump.isRemovedOnCompletion = false
            bump.beginTime = baseTime + Double(index) * 0.18
            dot.add(bump, forKey: "iremote.analysis.bump")
        }
    }

    private func stopAnalysisAnimation() {
        analysisContainer.sublayers?.forEach { $0.removeAllAnimations() }
    }

    private func layoutAnalysisLayers() {
        let bounds = analysisContainer.bounds
        // Ring lives in the top portion of the view so the typing dots can
        // sit below without overlap. Anchor each shape layer's frame to the
        // ring rect itself so transform.rotation pivots dead-centre.
        let ringDiameter: CGFloat = min(bounds.width, bounds.height) - 7
        let ringX = (bounds.width - ringDiameter) / 2.0
        let ringY = bounds.height - ringDiameter - 1
        let ringFrame = CGRect(x: ringX, y: ringY, width: ringDiameter, height: ringDiameter)
        let localPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: ringDiameter, height: ringDiameter), transform: nil)

        analysisRing?.path = localPath
        analysisRing?.frame = ringFrame
        analysisArc?.path = localPath
        analysisArc?.frame = ringFrame
        analysisArc?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        analysisArc?.position = CGPoint(x: ringFrame.midX, y: ringFrame.midY)

        guard analysisDots.count == 3 else { return }
        let dotSize: CGFloat = 2.1
        let dotGap: CGFloat = 2.4
        let totalWidth = CGFloat(analysisDots.count) * dotSize + CGFloat(analysisDots.count - 1) * dotGap
        let startX = bounds.midX - totalWidth / 2.0 + dotSize / 2.0
        let dotsY: CGFloat = 2.6
        for (index, dot) in analysisDots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.position = CGPoint(x: startX + CGFloat(index) * (dotSize + dotGap), y: dotsY)
            dot.cornerRadius = dotSize / 2.0
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
    }

    private func refreshLayerColors() {
        let strong = glyphColor(alpha: 0.96)
        let dim = glyphColor(alpha: 0.28)
        waveBars.forEach { $0.backgroundColor = strong }
        analysisRing?.strokeColor = dim
        analysisArc?.strokeColor = strong
        analysisDots.forEach { $0.backgroundColor = strong }
    }

    private func glyphColor(alpha: CGFloat) -> CGColor {
        let darkMatches: [NSAppearance.Name] = [.darkAqua, .vibrantDark]
        let match = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        let base: NSColor = match.map { darkMatches.contains($0) } == true ? .white : .black
        return base.withAlphaComponent(alpha).cgColor
    }
}
