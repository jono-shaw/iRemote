import AppKit

/// Live status of the macOS Bluetooth-debug configuration profile
/// (`Bluetooth_macOS.mobileconfig`).
///
/// The profile is installed system-wide and grants PacketLogger the
/// entitlements it needs to capture private BLE HID traffic from the
/// Siri Remote. Without it PacketLogger still runs, the helper still
/// thinks everything is fine, but `/tmp/iremote-window-live/remote.pklg`
/// never receives bytes — MENU / touchpad / Siri-mic all go dead.
///
/// **Two signals, one truth.**
/// 1. **Helper `profile-status`** (authoritative). The helper script
///    runs `profiles list` under sudo and greps for the profile's
///    PayloadIdentifier (`com.apple.bluetooth.logging`). When the
///    helper answers we trust it — `profiles` is the canonical source.
/// 2. **Behavioural traffic check** (fallback). When the helper isn't
///    installed yet, or it returns `unknown`, we fall back to
///    measuring whether the BLE pklg file is growing. Modern Macs
///    have BLE traffic from keyboards/AirPods/etc. running all the
///    time, so a 15-second drought is strong evidence that
///    PacketLogger isn't receiving anything (almost always = missing
///    profile).
///
/// **Restart detection.** If the user installs the profile while the
/// app is running, PacketLogger was already spawned without the
/// entitlement and won't pick up the change. We detect this
/// transition (helper status flipped from missing → installed during
/// this session) and surface a separate `.needsRestart` state, which
/// the menu renders with a yellow warning and a "Restart iRemote"
/// affordance.
@MainActor
final class ProfileMonitor {

    enum Status: Equatable {
        case listenerStopped     // listener paused or not yet started
        case starting            // listener active < grace seconds, no bytes yet
        case captureActive       // profile installed & bytes flowing
        case captureStalled      // profile reported missing / no traffic seen
        case needsRestart        // profile installed mid-session but capture hasn't recovered
    }

    /// Called on every status transition (main thread).
    var onStatusChange: ((Status) -> Void)?

    /// Supplied by AppDelegate; runs the privileged helper's
    /// `profile-status` command and returns the result. Allowed to
    /// return `.unknown` (helper not yet installed → we use the
    /// behavioural fallback).
    var helperStatusProvider: (() async -> RemoteDictationService.HelperProfileStatus)?

    private(set) var status: Status = .listenerStopped {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    /// True while the iRemote listener is configured to capture BLE.
    /// AppDelegate flips this when starting / stopping the listener.
    var listenerIsActive: Bool = false {
        didSet {
            if listenerIsActive && !oldValue {
                listenerStartedAt = Date()
                lastCaptureByteCount = 0
                lastCaptureGrowthAt = .distantPast
            } else if !listenerIsActive {
                listenerStartedAt = nil
            }
            recompute()
        }
    }

    private var listenerStartedAt: Date?
    private var lastCaptureByteCount: Int = 0
    private var lastCaptureGrowthAt: Date = .distantPast
    private var timer: Timer?
    private var helperPollTask: Task<Void, Never>?
    /// Most recent answer from the helper, or `.unknown` if we haven't
    /// asked yet / the helper isn't installed.
    private var helperProfileInstalled: RemoteDictationService.HelperProfileStatus = .unknown
    /// True once we have observed a `.missing → .installed` transition
    /// during this session. Drives the `.needsRestart` state so the
    /// user gets a clear "quit and reopen" nudge after installing the
    /// profile.
    private var sawMissingToInstalledTransition = false

    /// How long the listener can run without any BLE bytes before we
    /// declare the profile broken via the behavioural fallback.
    private let stallThresholdSeconds: TimeInterval = 15
    /// Grace period after listener start before we'll call it stalled.
    private let startupGraceSeconds: TimeInterval = 5
    /// How often we re-evaluate via the timer. The captureActive events
    /// already drive instant transitions to .captureActive; this timer
    /// catches the *no event* case where we'd otherwise stay green
    /// forever after a single byte.
    private let recomputeIntervalSeconds: TimeInterval = 3
    /// How often we re-query the helper. The cost is one sudo + one
    /// `profiles list` per poll; 6 s feels timely without being noisy.
    private let helperPollIntervalSeconds: TimeInterval = 6

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: recomputeIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        startHelperPoll()
        recompute()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        helperPollTask?.cancel()
        helperPollTask = nil
    }

    /// Force a helper poll immediately. Called after the user clicks
    /// "Install Bluetooth Profile…" so the new status is reflected
    /// without waiting for the next 6 s tick.
    func pokeHelperPoll() {
        Task { @MainActor in await self.queryHelperOnce() }
    }

    /// Wired to `RemoteListenerEvent.captureActive(byteCount:)`. Any
    /// growth in the pklg file = bytes flowing = profile working.
    func noteCaptureActive(byteCount: Int) {
        let now = Date()
        if byteCount != lastCaptureByteCount {
            lastCaptureByteCount = byteCount
            lastCaptureGrowthAt = now
        }
        recompute()
    }

    private func startHelperPoll() {
        helperPollTask?.cancel()
        helperPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.queryHelperOnce()
                let interval = self?.helperPollIntervalSeconds ?? 6
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func queryHelperOnce() async {
        guard let provider = helperStatusProvider else { return }
        let result = await provider()
        applyHelperResult(result)
    }

    private func applyHelperResult(_ newValue: RemoteDictationService.HelperProfileStatus) {
        let previous = helperProfileInstalled
        helperProfileInstalled = newValue
        if previous == .missing && newValue == .installed {
            sawMissingToInstalledTransition = true
        }
        if newValue == .installed && sawMissingToInstalledTransition == false && previous == .unknown {
            // First-ever answer is "installed" — no transition to flag.
        }
        recompute()
    }

    private func recompute() {
        let newStatus: Status
        if !listenerIsActive {
            newStatus = .listenerStopped
        } else {
            let now = Date()
            let elapsedSinceStart = listenerStartedAt.map { now.timeIntervalSince($0) } ?? .infinity
            let elapsedSinceGrowth = now.timeIntervalSince(lastCaptureGrowthAt)
            let bytesFlowing = elapsedSinceGrowth < stallThresholdSeconds

            switch helperProfileInstalled {
            case .installed:
                if bytesFlowing {
                    newStatus = .captureActive
                } else if sawMissingToInstalledTransition && elapsedSinceStart >= startupGraceSeconds {
                    // Profile became installed mid-session but
                    // PacketLogger was already running without the
                    // entitlement → restart needed.
                    newStatus = .needsRestart
                } else if elapsedSinceStart < startupGraceSeconds {
                    newStatus = .starting
                } else {
                    // Helper says installed, no transition was seen,
                    // and no traffic — likely a transient quiet
                    // moment. Stay neutral rather than alarm.
                    newStatus = .starting
                }
            case .missing:
                newStatus = .captureStalled
            case .unknown:
                if bytesFlowing {
                    newStatus = .captureActive
                } else if elapsedSinceStart < startupGraceSeconds {
                    newStatus = .starting
                } else {
                    newStatus = .captureStalled
                }
            }
        }
        status = newStatus
    }
}

extension ProfileMonitor.Status {
    /// SF Symbol name for the menu indicator. Use a checkmark for
    /// the success state and a triangular warning for the failure
    /// state — both are core macOS HIG idioms and read instantly
    /// without colour cues.
    var symbolName: String {
        switch self {
        case .listenerStopped: return "pause.circle"
        case .starting:        return "arrow.triangle.2.circlepath"
        case .captureActive:   return "checkmark.circle.fill"
        case .captureStalled:  return "exclamationmark.triangle.fill"
        case .needsRestart:    return "exclamationmark.triangle.fill"
        }
    }

    /// Tint colour for the menu indicator. Successful state uses
    /// `.systemGreen`; failure / warning states use `.systemYellow`
    /// rather than red because they're recoverable — installing or
    /// restarting fixes the situation. Neutral states inherit
    /// `labelColor` so they match the rest of the menu text.
    var tintColor: NSColor {
        switch self {
        case .listenerStopped: return .labelColor
        case .starting:        return .labelColor
        case .captureActive:   return .systemGreen
        case .captureStalled:  return .systemYellow
        case .needsRestart:    return .systemYellow
        }
    }

    /// User-facing label. Avoids the "BLE profile" jargon — the user
    /// pointed out (correctly) that nobody but the developer knows
    /// what that means. "Bluetooth Access" reads cleanly next to the
    /// "Install Bluetooth Profile…" action immediately below; title
    /// case matches the convention macOS uses for sentence-leading
    /// menu labels.
    var menuText: String {
        switch self {
        case .listenerStopped: return "Bluetooth Access: Idle (listener paused)"
        case .starting:        return "Bluetooth Access: Checking…"
        case .captureActive:   return "Bluetooth Access: Active"
        case .captureStalled:  return "Bluetooth Access: Setup needed"
        case .needsRestart:    return "Bluetooth Access: Restart iRemote to activate"
        }
    }
}
