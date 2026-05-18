import AppKit

/// Two-step touchpad calibration UI. The user is asked to swipe DOWN
/// and then RIGHT on the Siri Remote touchpad. The net raw delta of
/// each contact is recorded; together they produce the calibration
/// basis. Result is saved via `TouchpadCalibration.saveToDefaults()`
/// and reported back through `onComplete`.
///
/// **Why two swipes is enough.** Two non-parallel basis vectors fully
/// determine a 2D linear transform. Asking the user for up/down/left/
/// right separately would just give us four samples of the same two
/// basis vectors — extra friction for no extra information.
///
/// **Sample routing.** The driver does not own this window; the app
/// delegate forwards every touchpad sample to whichever consumer is
/// active. While this window is on screen, samples flow into
/// `handleSample(_:)` and bypass `TrackpadDriver.onSample(_:)`. That
/// keeps calibration deterministic — the focus dot isn't moving while
/// you're trying to capture a clean swipe.
@MainActor
final class CalibrationWindowController: NSWindowController, NSWindowDelegate {

    enum Step {
        case introducing
        case capturingDown
        case capturingRight
        case done
    }

    // MARK: - Public surface

    /// Fired when the user finishes the flow (with a valid calibration),
    /// skips both steps (leaving identity), or cancels (nil).
    var onComplete: ((TouchpadCalibration?) -> Void)?

    /// True when the window is on-screen and should be receiving touch
    /// samples instead of the trackpad driver.
    var isActive: Bool { window?.isVisible == true && step != .done }

    // MARK: - State

    private var step: Step = .introducing {
        didSet { syncUI() }
    }

    private var isCurrentlyTouching = false
    private var touchLastX: Int?
    private var touchLastY: Int?
    private var touchNetDx: Int = 0
    private var touchNetDy: Int = 0

    private var capturedDown: (Double, Double)?
    private var capturedRight: (Double, Double)?

    private var didReportCompletion = false

    // MARK: - UI

    private let titleLabel = NSTextField(labelWithString: "Touchpad Calibration")
    private let stepLabel = NSTextField(labelWithString: "")
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let liveLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "Begin", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Touchpad Calibration"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        syncUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        stepLabel.font = .systemFont(ofSize: 11, weight: .regular)
        stepLabel.textColor = .secondaryLabelColor
        promptLabel.font = .systemFont(ofSize: 13)
        promptLabel.preferredMaxLayoutWidth = 400
        promptLabel.lineBreakMode = .byWordWrapping
        liveLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        liveLabel.textColor = .tertiaryLabelColor

        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed)
        primaryButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let buttonRow = NSStackView(views: [NSView(), cancelButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fill

        let stack = NSStackView(views: [titleLabel, stepLabel, promptLabel, liveLabel, NSView(), buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 24),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -24),
        ])
    }

    private func syncUI() {
        switch step {
        case .introducing:
            stepLabel.stringValue = ""
            promptLabel.stringValue = "Calibrate the Siri Remote touchpad so that swiping in any direction moves the on-screen focus in the same direction.\n\nYou will perform two swipes: one DOWN and one RIGHT. Between swipes, lift your finger off the touchpad."
            primaryButton.title = "Begin"
            cancelButton.title = "Cancel"
            liveLabel.stringValue = ""
        case .capturingDown:
            stepLabel.stringValue = "Step 1 of 2 — DOWN"
            promptLabel.stringValue = "Place your finger on the touchpad and slide it DOWNWARD (from top edge toward bottom edge of the touchpad). Lift your finger to capture the swipe."
            primaryButton.title = "Skip this step"
            cancelButton.title = "Cancel"
            liveLabel.stringValue = "Waiting for touch…"
        case .capturingRight:
            stepLabel.stringValue = "Step 2 of 2 — RIGHT"
            promptLabel.stringValue = "Now slide your finger RIGHTWARD across the touchpad (from left edge toward right edge). Lift your finger to capture the swipe."
            primaryButton.title = "Skip this step"
            cancelButton.title = "Cancel"
            liveLabel.stringValue = "Waiting for touch…"
        case .done:
            stepLabel.stringValue = ""
            promptLabel.stringValue = "Calibration saved. The touchpad now treats your swipes as DOWN and RIGHT according to the gestures you just performed. You can re-run this any time from the iRemote menu."
            primaryButton.title = "Close"
            cancelButton.title = "Re-calibrate"
            liveLabel.stringValue = ""
        }
    }

    // MARK: - Sample handling

    /// Called from `AppDelegate.handleTouchpadSample` while this window
    /// is active. Captures one full touch contact per step.
    func handleSample(_ sample: RemoteTouchpadSample) {
        guard step == .capturingDown || step == .capturingRight else { return }

        let x = Int(sample.x)
        let y = Int(sample.y)

        if sample.isTouching {
            if !isCurrentlyTouching {
                isCurrentlyTouching = true
                touchLastX = x
                touchLastY = y
                touchNetDx = 0
                touchNetDy = 0
                liveLabel.stringValue = "Capturing…"
            } else if let prevX = touchLastX, let prevY = touchLastY {
                let dx = wrappedDelta(current: x, previous: prevX)
                let dy = wrappedDelta(current: y, previous: prevY)
                touchNetDx += dx
                touchNetDy += dy
                touchLastX = x
                touchLastY = y
                liveLabel.stringValue = String(format: "Net raw delta: (%+d, %+d)", touchNetDx, touchNetDy)
            }
        } else if isCurrentlyTouching {
            // Touch ended — evaluate the net delta.
            isCurrentlyTouching = false
            let dx = Double(touchNetDx)
            let dy = Double(touchNetDy)
            let magnitude = (dx * dx + dy * dy).squareRoot()
            touchLastX = nil
            touchLastY = nil

            if magnitude < 200 {
                liveLabel.stringValue = "Swipe too short — try again with a longer motion."
                return
            }

            if step == .capturingDown {
                capturedDown = (dx, dy)
                liveLabel.stringValue = String(format: "Down captured: (%+d, %+d). Now swipe RIGHT.", touchNetDx, touchNetDy)
                step = .capturingRight
            } else {
                capturedRight = (dx, dy)
                liveLabel.stringValue = String(format: "Right captured: (%+d, %+d).", touchNetDx, touchNetDy)
                completeCalibration()
            }
        }
    }

    private func wrappedDelta(current: Int, previous: Int) -> Int {
        var delta = current - previous
        if delta > 32_767 { delta -= 65_536 }
        else if delta < -32_768 { delta += 65_536 }
        return delta
    }

    private func completeCalibration() {
        guard let down = capturedDown, let right = capturedRight,
              let calibration = TouchpadCalibration.from(downGesture: down, rightGesture: right) else {
            // Degenerate result (e.g. two near-parallel swipes). Restart.
            capturedDown = nil
            capturedRight = nil
            liveLabel.stringValue = "Could not derive a valid calibration. Please try again."
            step = .capturingDown
            return
        }

        calibration.saveToDefaults()
        step = .done
        if !didReportCompletion {
            didReportCompletion = true
            onComplete?(calibration)
        }
    }

    // MARK: - Buttons

    @objc private func primaryPressed() {
        switch step {
        case .introducing:
            step = .capturingDown
        case .capturingDown:
            // User-requested skip — fall through with identity for down.
            capturedDown = (0, 1)
            step = .capturingRight
        case .capturingRight:
            capturedRight = (1, 0)
            completeCalibration()
        case .done:
            close()
        }
    }

    @objc private func cancelPressed() {
        switch step {
        case .done:
            // Re-calibrate
            capturedDown = nil
            capturedRight = nil
            didReportCompletion = false
            step = .capturingDown
        default:
            if !didReportCompletion {
                didReportCompletion = true
                onComplete?(nil)
            }
            close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !didReportCompletion {
            didReportCompletion = true
            onComplete?(nil)
        }
    }
}
