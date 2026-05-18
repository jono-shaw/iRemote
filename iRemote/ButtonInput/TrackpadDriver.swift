import AppKit
import ApplicationServices

/// iPadOS-style trackpad navigation for the Siri Remote.
///
/// Sliding the touchpad never posts mouse-move events. It moves an internal
/// focus point, hit-tests the macOS Accessibility tree at that point, and asks
/// `TrackpadFocusOverlay` to highlight the matched UI element. Clickpad release
/// promotes the target app/window and posts a real mouse click at the focus
/// point so blank areas and cross-app UI behave like normal cursor clicks.
/// AXPress/AXSelected/AXFocused remain as fallback activation paths.
@MainActor
final class TrackpadDriver {
    private struct FocusTarget {
        let element: AXUIElement
        let frame: CGRect
        let role: String
        let actions: [String]

        var canPress: Bool { actions.contains(kAXPressAction as String) }
    }

    private let overlay = TrackpadFocusOverlay()
    private let systemWideElement = AXUIElementCreateSystemWide()
    private var focusPoint: CGPoint
    private var selectedTarget: FocusTarget?
    private var lastX: Int?
    private var lastY: Int?
    private var lastSampleTime: TimeInterval?
    private var smoothedDx = 0.0
    private var smoothedDy = 0.0
    private var wasClickPressed = false
    private var isPressed = false

    /// Empirically-derived transform from raw BLE touchpad deltas to
    /// screen-space deltas in AX/CG top-left coordinates. Loaded from
    /// `UserDefaults` at init; defaults to identity (pass-through) when
    /// the user has not yet run the calibration flow.
    private var calibration: TouchpadCalibration

    private let xSensitivity: Double
    private let ySensitivity: Double
    private let allowMouseFallback: Bool
    private let debugLog: TrackpadDebugLog?
    private let deadZoneRawUnits = 2
    /// Raw-unit threshold that counts as "intentional motion" — used
    /// to wake the focus point out of click-stabilization. Below this
    /// the user is presumed to be settling for a press, not actually
    /// scrolling.
    private let significantMotionRawUnits = 5
    /// Dead-zone applied while the focus point is in click-stabilization
    /// mode (see `stabilizationDelay`). Bigger than the resting dead
    /// zone so the small tremors that happen while a finger is being
    /// pressed down don't drift the focus dot off-target.
    private let stabilizationDeadZoneRawUnits = 6
    /// Window of low-motion time, after which we assume the user is
    /// preparing to click and tighten the dead-zone. The signal flips
    /// back instantly on any motion above `significantMotionRawUnits`.
    private let stabilizationDelay: TimeInterval = 0.085
    private let motionSmoothingAlpha = 0.62
    private let sampleGapResetSeconds: TimeInterval = 0.18
    private let discontinuityResetRawUnits = 20_000
    private let hysteresisPadding: CGFloat = 18
    private let idleHideSeconds: TimeInterval = 1.1
    private let promotionInterval: TimeInterval = 0.35
    private var lastPromotedPID: pid_t?
    private var lastPromotionTime: TimeInterval = 0
    /// Timestamp of the most recent sample that crossed the
    /// "intentional motion" threshold. The gap between this and the
    /// current sample time controls whether we're in stabilization.
    private var lastSignificantMotionAt: TimeInterval = 0

    /// Multi-click bookkeeping. macOS distinguishes single / double /
    /// triple clicks by the `kCGMouseEventClickState` field on the
    /// CGEvent; recipients (Finder, text editors, etc.) read this to
    /// decide whether to "select" or "open" / start a word selection
    /// / start a paragraph selection. We mirror real mouse behaviour:
    /// successive presses within `NSEvent.doubleClickInterval` and
    /// close to the previous click's screen position keep incrementing
    /// the click count (capped at 3 — triple is the highest macOS uses).
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var lastClickCount: Int = 0
    private var lastClickTargetID: ObjectIdentifier?
    private let multiClickRadius: CGFloat = 8

    init() {
        let env = ProcessInfo.processInfo.environment
        let base = Double(env["IREMOTE_TRACKPAD_SENSITIVITY"] ?? "") ?? 0.024

        // Keep the visual focus point slower than the raw Remote coordinates.
        // The overlay interpolates between these target points, so lower values
        // improve control without making the rendered motion feel choppy.
        //
        // v40: bumped both axes ~14% from the v39 (0.07 / 0.60) values
        // after the user reported v39 felt a touch too slow. Ratios
        // preserved (Y is still ~8.5× X) so the touchpad's short-Y
        // / long-X aspect remains balanced; absolute scale is just
        // slightly hotter.
        self.xSensitivity = Double(env["IREMOTE_TRACKPAD_X_SENSITIVITY"] ?? "") ?? base * 0.08
        self.ySensitivity = Double(env["IREMOTE_TRACKPAD_Y_SENSITIVITY"] ?? "") ?? base * 0.685

        // Coordinate model: `focusPoint` is stored in AX/CG top-left screen
        // coordinates (positive Y = down). The raw → screen mapping comes
        // entirely from `calibration`. There is no longer any sign-flip
        // toggle (`yDirection`, `invertY`, etc.) — every previous version's
        // attempt at guessing the right sign has failed. The user calibrates
        // once via "Calibrate Touchpad…" and the matrix lives in
        // UserDefaults from then on.
        self.calibration = TouchpadCalibration.loadFromDefaults()
        self.allowMouseFallback = env["IREMOTE_TRACKPAD_MOUSE_FALLBACK"] == "1"
        self.debugLog = env["IREMOTE_TRACKPAD_DEBUG"] == "1" ? TrackpadDebugLog() : nil

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.frame
            self.focusPoint = CGPoint(x: f.midX, y: f.height / 2.0)
        } else {
            self.focusPoint = CGPoint(x: 400, y: 300)
        }
    }

    /// Swap in a freshly-saved calibration without rebooting the driver.
    /// Called from `AppDelegate` after the calibration window completes.
    func applyCalibration(_ calibration: TouchpadCalibration) {
        self.calibration = calibration
    }

    func onSample(_ sample: RemoteTouchpadSample) {
        updateClickState(sample: sample)

        guard sample.isTouching else {
            resetTouchTracking()
            selectedTarget = nil
            overlay.scheduleHide(after: idleHideSeconds)
            return
        }

        let x = Int(sample.x)
        let y = Int(sample.y)
        let sampleTime = CFAbsoluteTimeGetCurrent()
        defer {
            lastX = x
            lastY = y
            lastSampleTime = sampleTime
        }

        guard let prevX = lastX, let prevY = lastY, let prevSampleTime = lastSampleTime else {
            resetMotionState()
            updateSelection(at: focusPoint)
            return
        }

        if sampleTime - prevSampleTime > sampleGapResetSeconds {
            resetMotionState()
            updateSelection(at: focusPoint)
            return
        }

        var rawDx = wrappedDelta(current: x, previous: prevX)
        var rawDy = wrappedDelta(current: y, previous: prevY)
        guard abs(rawDx) <= discontinuityResetRawUnits,
              abs(rawDy) <= discontinuityResetRawUnits else {
            resetMotionState()
            updateSelection(at: focusPoint)
            return
        }

        // Click stabilization: when the user pauses their finger to
        // press the clickpad, tiny tremors leak through as ~3-5 raw
        // units of motion per sample. Without help, the focus dot
        // drifts off the intended target by the time the press
        // registers (the v40 user report). Standard pro-trackpad
        // behaviour: as soon as motion velocity drops, freeze the
        // dot until intentional motion resumes. We implement this by
        // widening the dead-zone after `stabilizationDelay` of
        // sub-significant motion; any raw delta at or above
        // `significantMotionRawUnits` instantly resets the timer and
        // restores normal sensitivity.
        let rawMagnitude = max(abs(rawDx), abs(rawDy))
        if rawMagnitude >= significantMotionRawUnits {
            lastSignificantMotionAt = sampleTime
        }
        let stabilizing = (sampleTime - lastSignificantMotionAt) > stabilizationDelay
        let activeDeadZone = stabilizing ? stabilizationDeadZoneRawUnits : deadZoneRawUnits
        if abs(rawDx) <= activeDeadZone { rawDx = 0 }
        if abs(rawDy) <= activeDeadZone { rawDy = 0 }
        guard rawDx != 0 || rawDy != 0 else {
            updateSelection(at: focusPoint)
            return
        }

        // Project raw delta onto the calibrated basis. With identity
        // calibration this is a no-op (`visualDx == rawDx`,
        // `visualDy == rawDy`); after the user calibrates, the matrix
        // encodes the correct mapping regardless of remote orientation
        // or BLE Y-axis origin.
        let (visualDx, visualDy) = calibration.mapDelta(rawDx: rawDx, rawDy: rawDy)

        let dx = smoothedMotion(input: visualDx * xSensitivity, previous: &smoothedDx)
        let dy = smoothedMotion(input: visualDy * ySensitivity, previous: &smoothedDy)

        var newPoint = CGPoint(x: focusPoint.x + dx, y: focusPoint.y + dy)
        clampToPrimaryScreen(&newPoint)
        focusPoint = newPoint

        debugLog?.append(
            rawX: x, rawY: y,
            rawDx: rawDx, rawDy: rawDy,
            visualDx: visualDx, visualDy: visualDy,
            outDx: dx, outDy: dy,
            focusX: focusPoint.x, focusY: focusPoint.y
        )

        updateSelection(at: focusPoint)
    }

    // MARK: - Motion normalization

    private func resetTouchTracking() {
        lastX = nil
        lastY = nil
        lastSampleTime = nil
        resetMotionState()
    }

    private func resetMotionState() {
        smoothedDx = 0
        smoothedDy = 0
    }

    private func wrappedDelta(current: Int, previous: Int) -> Int {
        var delta = current - previous
        if delta > 32_767 {
            delta -= 65_536
        } else if delta < -32_768 {
            delta += 65_536
        }
        return delta
    }

    private func smoothedMotion(input: Double, previous: inout Double) -> Double {
        previous = input * motionSmoothingAlpha + previous * (1.0 - motionSmoothingAlpha)
        return abs(previous) < 0.04 ? 0 : previous
    }

    // MARK: - Selection

    private func updateSelection(at point: CGPoint) {
        if let current = selectedTarget,
           current.frame.insetBy(dx: -hysteresisPadding, dy: -hysteresisPadding).contains(point) {
            // CRITICAL: do *not* re-call `promoteElementToFront`
            // here. v41 added a per-sample re-promote in this
            // "still hovering the same target" branch so the app
            // would stay active during dwell. It turned out that
            // also undoes any destructive action the user just
            // triggered on the same target.
            //
            // Concrete failure mode (window minimize):
            //   1. AXPress on the yellow minimize button → window
            //      starts animating to the Dock. `lastPromotionTime`
            //      is set to the click moment.
            //   2. BLE samples keep firing at ~60 Hz. The
            //      `promotionInterval` debounce (350 ms) suppresses
            //      this branch's re-promote for the first ~350 ms.
            //   3. The moment the debounce expires, the next sample
            //      hits AXRaise + `AXMain = true` on the *minimized*
            //      window's element. AppKit interprets AXMain=true
            //      on a minimized window as "make this the main
            //      window," which requires it visible — so it
            //      restores from the Dock. The user sees the
            //      minimize "immediately" undone (~350 ms is
            //      effectively immediate).
            //
            // The fix: the initial promote happens via `focus()`
            // when the target is first selected (the else branch
            // below); a click then does its own force-true promote
            // in `activateSelection`. A constant re-assert while
            // dwelling is redundant in healthy states and
            // catastrophic after a destructive action.
            overlay.showSelection(frame: current.frame)
            syncSystemCursor(to: point)
            return
        }

        guard let target = resolveTarget(at: point) else {
            selectedTarget = nil
            if let hit = copyHitElement(at: point) {
                promoteElementToFront(hit)
            }
            overlay.showPoint(at: point)
            syncSystemCursor(to: point)
            return
        }

        selectedTarget = target
        focus(target)
        overlay.showSelection(frame: target.frame)
        syncSystemCursor(to: point)
    }

    private func resolveTarget(at point: CGPoint) -> FocusTarget? {
        guard AXIsProcessTrusted() else { return nil }
        return resolveTargetOnce(at: point)
    }

    private func resolveTargetOnce(at point: CGPoint) -> FocusTarget? {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard error == .success, let hit else { return nil }

        var element = hit
        for _ in 0..<7 {
            if let target = makeTarget(from: element) {
                return target
            }
            guard let parent = copyElementAttribute(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    private func makeTarget(from element: AXUIElement) -> FocusTarget? {
        guard let role = copyStringAttribute(element, kAXRoleAttribute),
              let frame = copyFrame(element),
              isUsableFrame(frame) else { return nil }

        let actions = copyActionNames(element)
        let canSelect = actions.contains(kAXPressAction as String)
            || selectableRoles.contains(role)
            || focusableRoles.contains(role)
        guard canSelect else { return nil }

        return FocusTarget(element: element, frame: frame, role: role, actions: actions)
    }

    private var selectableRoles: Set<String> {
        [
            "AXButton",
            "AXCheckBox",
            "AXRadioButton",
            "AXPopUpButton",
            "AXMenuItem",
            "AXMenuButton",
            "AXTabGroup",
            "AXLink",
            "AXCell",
            "AXRow",
            "AXDisclosureTriangle",
            "AXSlider",
            "AXValueIndicator",
        ]
    }

    private var focusableRoles: Set<String> {
        [
            "AXTextField",
            "AXTextArea",
            "AXSearchField",
            "AXComboBox",
        ]
    }

    private func isUsableFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 6, frame.height >= 6 else { return false }
        guard let primary = NSScreen.screens.first else { return true }
        let screenArea = primary.frame.width * primary.frame.height
        let area = frame.width * frame.height
        if area > screenArea * 0.55 { return false }
        if frame.width > primary.frame.width * 0.92 { return false }
        if frame.height > primary.frame.height * 0.72 { return false }
        return frame.intersects(CGRect(x: 0, y: 0, width: primary.frame.width, height: primary.frame.height))
    }

    private func focus(_ target: FocusTarget) {
        promoteElementToFront(target.element)
        _ = AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    // MARK: - Click handling

    private func updateClickState(sample: RemoteTouchpadSample) {
        let nowPressed = sample.isClicked && sample.isTouching
        if nowPressed && !wasClickPressed {
            wasClickPressed = true
            isPressed = true
            overlay.setPressed(true)
        } else if !nowPressed && wasClickPressed {
            wasClickPressed = false
            isPressed = false
            overlay.setPressed(false)
            activateSelection()
        }
    }

    func leftClickDown() {
        guard !isPressed else { return }
        isPressed = true
        overlay.setPressed(true)
    }

    func leftClickUp() {
        guard isPressed else { return }
        isPressed = false
        overlay.setPressed(false)
        activateSelection()
    }

    @discardableResult
    private func activateSelection() -> Bool {
        // Compute multi-click count first. Successive presses within
        // `NSEvent.doubleClickInterval` at roughly the same screen
        // position increment the count up to 3 (single / double /
        // triple). This matches real mouse behaviour and is what
        // Finder, text editors, etc. read via
        // `kCGMouseEventClickState` on the CGEvent.
        let clickCount = nextClickCount()

        // Precision path: when a UI element is currently highlighted,
        // activate THAT element regardless of where focusPoint sits. The
        // visible highlight is what the user expects to click, and the
        // selection hysteresis pad lets `focusPoint` drift slightly
        // outside `selectedTarget.frame` while the highlight still
        // shows — clicking at `focusPoint` would miss the element by
        // exactly that hysteresis distance. Click at the element's
        // actual center instead, or skip the coordinate entirely via
        // AXPress (single click only — AXPress can't communicate a
        // multi-click count).
        if let target = selectedTarget {
            // Snap the system cursor to the target's centre before
            // any activation. Some apps fire follow-up logic based
            // on cursor position (e.g. Finder's window-restore
            // behaviour when the cursor lands on the Dock icon),
            // and if our cursor lagged behind focusPoint the
            // close-window AXPress could be undone by an unrelated
            // click landing wherever the cursor still was. Co-
            // locating cursor and click point eliminates this whole
            // class of bug.
            let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
            syncSystemCursor(to: center)

            let needsDelay = promoteElementToFront(target.element, force: true)
            if needsDelay {
                scheduleTargetActivation(target, clickCount: clickCount)
            } else {
                _ = performTargetActivation(target, clickCount: clickCount)
            }
            return true
        }

        // No highlighted element — focusPoint is in blank space or on
        // a non-actionable surface. Front whatever's there and post a
        // coordinate click at focusPoint so cross-app blank-area
        // clicks behave like a normal cursor click.
        syncSystemCursor(to: focusPoint)
        let promoted = copyHitElement(at: focusPoint).map {
            promoteElementToFront($0, force: true)
        } ?? false
        if promoted {
            scheduleMouseClick(clickCount: clickCount)
        } else {
            _ = postMouseClick(force: true, clickCount: clickCount)
        }
        return true
    }

    /// Move the macOS system cursor to follow our internal
    /// focus-point overlay. v40 used to leave the cursor wherever
    /// the user had it last, which produced two problems the user
    /// hit:
    ///   1. The cursor visibly diverged from the highlighted target,
    ///      making it look as though the click would land in the
    ///      wrong place.
    ///   2. Apps that read cursor position during a click (e.g.
    ///      Finder + window restoration, anything that pops a
    ///      tooltip / hover-menu based on cursor location) could see
    ///      a stale position and re-open windows we'd just closed.
    /// `CGWarpMouseCursorPosition` is silent — no synthesised
    /// mouseMoved cascade, no spurious tooltips — but still moves
    /// the cursor instantly. We re-associate mouse-and-cursor right
    /// after so the call doesn't disable real mouse input for the
    /// default 250 ms quarantine window.
    private func syncSystemCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Bumps `lastClick*` bookkeeping and returns the click count the
    /// next CGEvent should report. macOS uses 1 / 2 / 3 for single,
    /// double, and triple clicks respectively. We cap at 3 because no
    /// system control reads higher counts and they confuse some apps.
    private func nextClickCount() -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        let interval = NSEvent.doubleClickInterval
        let moved = hypot(focusPoint.x - lastClickPoint.x, focusPoint.y - lastClickPoint.y)
        let currentTargetID = selectedTarget.map { ObjectIdentifier($0.element) }
        // Continuation rule: within doubleClickInterval, AND either
        // (a) the focus point is within multiClickRadius of the last
        // click, OR (b) the same selectedTarget is highlighted. The
        // target check covers the case where a button's center moved
        // slightly (e.g. layout reflow during the first click) but
        // the user is still clicking the same thing.
        let positionMatches = moved < multiClickRadius
        let targetMatches = currentTargetID != nil && currentTargetID == lastClickTargetID
        let isContinuation = (now - lastClickTime) < interval && (positionMatches || targetMatches)
        let count = isContinuation ? min(lastClickCount + 1, 3) : 1
        lastClickTime = now
        lastClickPoint = focusPoint
        lastClickCount = count
        lastClickTargetID = currentTargetID
        return count
    }

    @discardableResult
    private func performTargetActivation(_ target: FocusTarget, clickCount: Int) -> Bool {
        let isOwnProcess = (copyPID(target.element) == getpid())

        // 1. AXPress — most precise activation possible. No coordinate
        //    involved, so misalignment between `focusPoint` and the
        //    element's frame cannot affect the outcome. Works for
        //    buttons, menu items, links, disclosure triangles, etc.
        //
        //    SKIPPED for multi-clicks: AXPress is a single discrete
        //    action and can't tell the recipient "this was the second
        //    click of a double". Use a CGEvent sequence with the
        //    correct click count instead.
        //
        //    SKIPPED for own-process targets: a synchronous AXPress
        //    that lands on one of our own AX elements re-enters the
        //    main thread through AppKit's AX handler. When the press
        //    triggers an action that starts modal tracking — most
        //    obviously, clicking our own menu-bar status icon to
        //    open its NSMenu — the modal-tracking event pump needs
        //    the same main thread the outer AXPress is still blocked
        //    on. End result in the field: clicking the iRemote
        //    menu-bar icon with the remote trackpad froze the app.
        //    CGEvent click (below) sidesteps the whole AX
        //    re-entrance because the click hops through the OS
        //    event queue, getting processed after the current
        //    BLE-sample handler returns.
        if clickCount == 1, !isOwnProcess, target.canPress,
           AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success {
            return true
        }

        // 2. CGEvent click at the element's CENTER. This is the
        //    coordinate-based fallback for elements that don't expose
        //    AXPress (custom controls, some web UIs), the only path
        //    that can carry a click count >= 2, and the *primary*
        //    path for own-process targets (see above). Crucially
        //    this uses `target.frame.midX/midY`, not `focusPoint` —
        //    the point where the user pressed the clickpad is
        //    irrelevant; the click lands inside the highlighted
        //    element by construction.
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        if postClick(at: center, clickCount: clickCount) {
            return true
        }

        // 3. Last resort: AXSelected / AXFocused on the element
        //    itself. Useful for things like list rows or text fields
        //    that respond to selection/focus without a real press.
        //    Setting an AX attribute on our own element is safe —
        //    the failure mode is "AppKit does nothing", not the
        //    deadlock AXPress can cause, because attribute setters
        //    don't start modal tracking.
        return setSelectedOrFocused(target.element)
    }

    private func scheduleTargetActivation(_ target: FocusTarget, clickCount: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            _ = self.performTargetActivation(target, clickCount: clickCount)
        }
    }

    @discardableResult
    private func postClick(at point: CGPoint, clickCount: Int = 1) -> Bool {
        guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return false }
        // `kCGMouseEventClickState` is the click-count field macOS
        // reads to decide single vs double vs triple click. Without
        // setting it, every CGEvent reports clickCount=1 and apps
        // never see a double-click pair.
        if clickCount > 1 {
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func activationCandidates(at point: CGPoint) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        if let hit = copyHitElement(at: point) {
            appendDescendantCandidates(from: hit, point: point, depth: 4, to: &candidates)
            appendAncestorCandidates(from: hit, to: &candidates)
        }

        if let selectedTarget {
            appendDescendantCandidates(from: selectedTarget.element, point: point, depth: 5, to: &candidates)
            appendAncestorCandidates(from: selectedTarget.element, to: &candidates)
        }

        return candidates
    }

    private func appendDescendantCandidates(
        from element: AXUIElement,
        point: CGPoint,
        depth: Int,
        to candidates: inout [AXUIElement]
    ) {
        guard depth >= 0 else { return }
        if let frame = copyFrame(element),
           !frame.insetBy(dx: -8, dy: -8).contains(point) {
            return
        }

        for child in copyElementArrayAttribute(element, kAXChildrenAttribute) {
            appendDescendantCandidates(from: child, point: point, depth: depth - 1, to: &candidates)
        }

        if canActivate(element) {
            appendUnique(element, to: &candidates)
        }
    }

    private func appendAncestorCandidates(from element: AXUIElement, to candidates: inout [AXUIElement]) {
        var current = element
        for _ in 0..<9 {
            if canActivate(current) {
                appendUnique(current, to: &candidates)
            }
            guard let parent = copyElementAttribute(current, kAXParentAttribute) else { break }
            current = parent
        }
    }

    private func canActivate(_ element: AXUIElement) -> Bool {
        let actions = copyActionNames(element)
        if actions.contains(kAXPressAction as String) { return true }

        guard let role = copyStringAttribute(element, kAXRoleAttribute) else { return false }
        return selectableRoles.contains(role) || focusableRoles.contains(role)
    }

    private func appendUnique(_ element: AXUIElement, to elements: inout [AXUIElement]) {
        guard !elements.contains(where: { CFEqual($0, element) }) else { return }
        elements.append(element)
    }

    @discardableResult
    private func pressElement(_ element: AXUIElement) -> Bool {
        let needsDelayedPress = prepareForActivation(element)
        if needsDelayedPress {
            schedulePress(element)
            return true
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    @discardableResult
    private func selectOrFocusElement(_ element: AXUIElement) -> Bool {
        let needsDelayedFocus = prepareForActivation(element)
        if needsDelayedFocus {
            scheduleSelectOrFocus(element)
            return true
        }
        return setSelectedOrFocused(element)
    }

    /// Some apps expose AX targets while inactive or behind another window.
    /// Move the target's app/window forward first, then retry the real action
    /// shortly after the frontmost state settles.
    @discardableResult
    private func prepareForActivation(_ element: AXUIElement) -> Bool {
        promoteElementToFront(element, force: true)
    }

    @discardableResult
    private func promoteElementToFront(_ element: AXUIElement, force: Bool = false) -> Bool {
        let pid = copyPID(element)
        let now = CFAbsoluteTimeGetCurrent()
        if !force,
           let pid,
           lastPromotedPID == pid,
           now - lastPromotionTime < promotionInterval {
            return false
        }

        var didPromote = false
        if let window = copyElementAttribute(element, kAXWindowAttribute)
            ?? copyElementAttribute(element, "AXTopLevelUIElement") {
            _ = AXUIElementPerformAction(window, "AXRaise" as CFString)
            _ = AXUIElementSetAttributeValue(window, "AXMain" as CFString, kCFBooleanTrue)
            didPromote = true
        }

        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            let wasActive = app.isActive
            // Skip the cross-app activation when the target's app is
            // already in the foreground. Re-activating an already-
            // active app has a nasty side effect in Finder (and a
            // few other "windowless-app" implementers): macOS's
            // app-activation policy creates a new window when an app
            // is activated with none open. That's exactly what
            // happens after AXPress closes the only Finder window —
            // the next focus update fires another
            // promoteElementToFront → app.activate → Finder spins up
            // a fresh window → from the user's perspective the
            // window we just closed "reopens." AXRaise on the
            // specific window above is enough to handle window-
            // level focus inside the active app.
            if !wasActive {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                didPromote = true
            }
            lastPromotedPID = pid
            lastPromotionTime = now
        } else if didPromote {
            lastPromotionTime = now
        }

        return didPromote
    }

    private func scheduleMouseClick(clickCount: Int = 1) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            _ = postMouseClick(force: true, clickCount: clickCount)
        }
    }

    private func schedulePress(_ element: AXUIElement) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 85_000_000)
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    private func scheduleSelectOrFocus(_ element: AXUIElement) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 85_000_000)
            _ = setSelectedOrFocused(element)
        }
    }

    @discardableResult
    private func setSelectedOrFocused(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }

        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }

        return false
    }

    // MARK: - Cursor click fallback

    @discardableResult
    private func postMouseClick(force: Bool = false, clickCount: Int = 1) -> Bool {
        guard force || allowMouseFallback else { return false }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: focusPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: focusPoint, mouseButton: .left)
        else { return false }
        if clickCount > 1 {
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func clampToPrimaryScreen(_ point: inout CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        point.x = min(max(point.x, 0), primary.frame.width)
        point.y = min(max(point.y, 0), primary.frame.height)
    }

    // MARK: - AX helpers

    private func copyHitElement(at point: CGPoint) -> AXUIElement? {
        copyHitElementOnce(at: point)
    }

    private func copyHitElementOnce(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard error == .success else { return nil }
        return hit
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    private func copyElementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
        return (actions as? [String]) ?? []
    }

    private func copyPID(_ element: AXUIElement) -> pid_t? {
        var pid = pid_t(0)
        if AXUIElementGetPid(element, &pid) == .success {
            return pid
        }

        var current = element
        for _ in 0..<8 {
            if let parent = copyElementAttribute(current, kAXParentAttribute) {
                current = parent
                if AXUIElementGetPid(current, &pid) == .success {
                    return pid
                }
            } else {
                break
            }
        }
        return nil
    }

    private func copyFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }

        return CGRect(origin: origin, size: size).standardized
    }
}
