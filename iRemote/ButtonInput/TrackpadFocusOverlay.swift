import AppKit

/// Floating focus highlight for Siri Remote touchpad selection.
///
/// When AX can resolve an element under the internal focus point, the overlay
/// wraps that UI element. In empty space it remains a small focus dot, so the
/// hidden navigation point is always visible while the remote touchpad is in use.
@MainActor
final class TrackpadFocusOverlay {
    private static let targetPadding: CGFloat = 5.0
    private static let minDimension: CGFloat = 18.0
    private static let pointDiameter: CGFloat = 18.0
    private static let pointWindowSize: CGFloat = 30.0
    private static let frameInterval: TimeInterval = 1.0 / 120.0
    private static let interpolation: CGFloat = 0.38

    private let window: NSPanel
    private let focusView: FocusView
    private var idleHideTask: Task<Void, Never>?
    private var currentFrame: NSRect?
    private var targetFrame: NSRect?
    private var motionTimer: Timer?

    init() {
        let frame = NSRect(x: 0, y: 0, width: Self.pointWindowSize, height: Self.pointWindowSize)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = false
        panel.animationBehavior = .none
        panel.alphaValue = 0.0

        let view = FocusView(frame: frame)
        panel.contentView = view
        self.window = panel
        self.focusView = view
    }

    /// `point` is in AX/CG screen coordinates, origin top-left on the primary
    /// display. The panel uses AppKit coordinates, origin bottom-left, so Y is
    /// flipped here.
    func showPoint(at point: CGPoint) {
        idleHideTask?.cancel()
        idleHideTask = nil

        guard let primary = NSScreen.screens.first else { return }
        let size = Self.pointWindowSize
        let nsX = point.x - size / 2.0
        let nsY = primary.frame.height - point.y - size / 2.0
        let panelFrame = NSRect(x: nsX, y: nsY, width: size, height: size)

        focusView.shape = .point
        focusView.pointDiameter = Self.pointDiameter
        show(targetFrame: panelFrame)
    }

    /// `frame` is in AX/CG screen coordinates, origin top-left on the primary
    /// display. The panel uses AppKit coordinates, origin bottom-left, so Y is
    /// flipped here.
    func showSelection(frame: CGRect) {
        idleHideTask?.cancel()
        idleHideTask = nil

        guard let primary = NSScreen.screens.first else { return }
        var rect = frame.standardized
        rect.size.width = max(rect.width, Self.minDimension)
        rect.size.height = max(rect.height, Self.minDimension)

        let paddedWidth = rect.width + Self.targetPadding * 2
        let paddedHeight = rect.height + Self.targetPadding * 2
        let nsX = rect.minX - Self.targetPadding
        let nsY = primary.frame.height - rect.maxY - Self.targetPadding
        let panelFrame = NSRect(x: nsX, y: nsY, width: paddedWidth, height: paddedHeight)

        focusView.shape = .selection
        show(targetFrame: panelFrame)
    }

    /// Hide after `delay` seconds with no further selected target. Calling
    /// `showPoint(at:)` or `showSelection(frame:)` cancels the pending hide.
    func scheduleHide(after delay: TimeInterval) {
        idleHideTask?.cancel()
        idleHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.fadeOut()
            }
        }
    }

    func setPressed(_ pressed: Bool) {
        focusView.isPressed = pressed
        focusView.needsDisplay = true
    }

    func hideImmediately() {
        idleHideTask?.cancel()
        idleHideTask = nil
        stopMotionTimer()
        window.alphaValue = 0.0
        window.orderOut(nil)
    }

    private func show(targetFrame frame: NSRect) {
        targetFrame = frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = window.isVisible

        if !wasVisible || currentFrame == nil || reduceMotion {
            apply(frame)
            currentFrame = frame
        } else {
            startMotionTimer()
        }

        if !wasVisible {
            window.alphaValue = 0.0
            window.orderFrontRegardless()
        }
        focusView.needsDisplay = true
        fadeIn()
    }

    private func startMotionTimer() {
        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMotionTimer() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func advanceFrame() {
        guard let target = targetFrame else {
            stopMotionTimer()
            return
        }
        guard let current = currentFrame else {
            currentFrame = target
            apply(target)
            stopMotionTimer()
            return
        }

        let next = current.interpolated(toward: target, amount: Self.interpolation)
        if next.isNearlyEqual(to: target, tolerance: 0.45) {
            currentFrame = target
            apply(target)
            stopMotionTimer()
        } else {
            currentFrame = next
            apply(next)
        }
    }

    private func apply(_ frame: NSRect) {
        window.setFrame(frame, display: true)
        focusView.frame = NSRect(origin: .zero, size: frame.size)
        focusView.needsDisplay = true
    }

    private func fadeIn() {
        guard window.alphaValue < 1.0 else { return }
        animate(duration: 0.08) {
            self.window.animator().alphaValue = 1.0
        }
    }

    private func fadeOut() {
        guard window.isVisible else { return }
        animate(duration: 0.10) {
            self.window.animator().alphaValue = 0.0
        } completion: {
            if self.window.alphaValue <= 0.01 {
                self.stopMotionTimer()
                self.window.orderOut(nil)
            }
        }
    }

    private func animate(duration: TimeInterval, changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0.0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }

    private final class FocusView: NSView {
        enum Shape {
            case point
            case selection
        }

        var shape: Shape = .point
        var pointDiameter: CGFloat = 18.0
        var isPressed: Bool = false

        override var isFlipped: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            switch shape {
            case .point:
                drawPoint()
            case .selection:
                drawSelection()
            }
        }

        private func drawPoint() {
            let side = min(pointDiameter, bounds.width - 4.0, bounds.height - 4.0)
            let rect = NSRect(
                x: bounds.midX - side / 2.0,
                y: bounds.midY - side / 2.0,
                width: side,
                height: side
            )
            let path = NSBezierPath(ovalIn: rect)

            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isPressed ? 0.32 : 0.24)
            shadow.shadowBlurRadius = isPressed ? 8 : 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()

            NSColor.systemBlue.withAlphaComponent(isPressed ? 0.96 : 0.88).setFill()
            path.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.92).setStroke()
            path.lineWidth = 2.2
            path.stroke()
        }

        private func drawSelection() {
            let rect = bounds.insetBy(dx: 2.0, dy: 2.0)
            let radius = min(14.0, max(8.0, rect.height / 2.3))
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isPressed ? 0.30 : 0.22)
            shadow.shadowBlurRadius = isPressed ? 8 : 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()

            NSColor.systemBlue.withAlphaComponent(isPressed ? 0.22 : 0.12).setFill()
            path.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.82).setStroke()
            path.lineWidth = 3.0
            path.stroke()

            NSColor.systemBlue.withAlphaComponent(isPressed ? 0.98 : 0.88).setStroke()
            path.lineWidth = 1.7
            path.stroke()
        }
    }
}

private extension NSRect {
    func interpolated(toward target: NSRect, amount: CGFloat) -> NSRect {
        NSRect(
            x: origin.x + (target.origin.x - origin.x) * amount,
            y: origin.y + (target.origin.y - origin.y) * amount,
            width: size.width + (target.size.width - size.width) * amount,
            height: size.height + (target.size.height - size.height) * amount
        )
    }

    func isNearlyEqual(to other: NSRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}
