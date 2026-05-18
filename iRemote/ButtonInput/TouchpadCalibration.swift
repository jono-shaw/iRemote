import Foundation

/// Empirically-determined transform that maps raw Siri Remote touchpad
/// deltas (decoded from BLE handle 0x0023 bytes 6-9 BE u16) into
/// screen-space deltas in AX/CG top-left coordinates
/// (positive Y = down on screen).
///
/// **Why this exists (history).** v18-v33 each tried to guess the
/// raw-to-screen mapping a priori — sign flags, bitmasks, aspect
/// scaling, per-touch locks, Schmitt triggers. None of those can solve
/// a problem whose answer depends on which BLE byte pair the firmware
/// puts X in, which origin the touchpad uses, and how the user holds
/// the remote. Commercial pointing devices solve this by asking the
/// user to perform reference gestures and storing the result.
///
/// **v34 tried a 2D matrix and was wrong.** v34 stored two unit basis
/// vectors and applied a dot-product projection. That's the right
/// transform only when the basis is *orthonormal*. The user's two
/// calibration swipes are almost never perfectly perpendicular — the
/// Siri Remote touchpad is small, the user's finger tracks at slight
/// angles — so the dot-product transform encodes a *rotation* into
/// every subsequent input. Pure-vertical motion became 45° diagonal
/// because the user's calibration swipes were diagonal-ish.
///
/// **v35 model.** The Siri Remote touchpad's X and Y axes are
/// physically orthogonal in raw space. There is no rotation to
/// recover. The only real degrees of freedom are:
///
/// - `swapAxes`: does raw byte-pair 6-7 carry "right" or "down"?
/// - `invertX`: does finger-right produce raw +X or raw -X?
/// - `invertY`: does finger-down produce raw +Y or raw -Y?
///
/// That's 3 bits = 8 configurations. Two reference gestures
/// (one DOWN, one RIGHT) determine all three bits unambiguously from
/// the dominant axis and sign of each gesture. Pure raw-X input
/// produces pure visual-X output (or pure visual-Y if swapped) —
/// **diagonal output from non-diagonal input is mathematically
/// impossible in this model**.
struct TouchpadCalibration: Equatable, Sendable {
    var swapAxes: Bool
    var invertX: Bool
    var invertY: Bool

    init(swapAxes: Bool = false, invertX: Bool = false, invertY: Bool = false) {
        self.swapAxes = swapAxes
        self.invertX = invertX
        self.invertY = invertY
    }

    static let identity = TouchpadCalibration()

    var isIdentity: Bool {
        !swapAxes && !invertX && !invertY
    }

    /// Maps a raw delta into screen-space delta. Pure-axis input
    /// always produces pure-axis output — never blended.
    func mapDelta(rawDx: Int, rawDy: Int) -> (Double, Double) {
        let rdx = Double(rawDx)
        let rdy = Double(rawDy)
        var visualDx = swapAxes ? rdy : rdx
        var visualDy = swapAxes ? rdx : rdy
        if invertX { visualDx = -visualDx }
        if invertY { visualDy = -visualDy }
        return (visualDx, visualDy)
    }

    /// Builds a calibration from two captured net-delta gestures: one
    /// swipe the user identified as "screen-DOWN" and one identified as
    /// "screen-RIGHT". Returns nil if either gesture is too small to
    /// determine direction reliably, or if the two gestures dominate
    /// the same physical axis (which means the user's swipes were
    /// inconsistent — typically because one of them was diagonal).
    static func from(downGesture: (Double, Double),
                     rightGesture: (Double, Double)) -> TouchpadCalibration? {
        let downX = downGesture.0
        let downY = downGesture.1
        let rightX = rightGesture.0
        let rightY = rightGesture.1

        let downMag = (downX * downX + downY * downY).squareRoot()
        let rightMag = (rightX * rightX + rightY * rightY).squareRoot()
        // Below this magnitude the gesture is noise rather than a swipe.
        // Typical full-touchpad sweeps are tens of thousands of raw units.
        guard downMag >= 200, rightMag >= 200 else { return nil }

        // Dominant axis of each gesture in raw space.
        let downDominantY = abs(downY) > abs(downX)
        let rightDominantX = abs(rightX) > abs(rightY)

        if downDominantY && rightDominantX {
            // Natural orientation: raw Y axis carries screen-Y motion,
            // raw X axis carries screen-X motion.
            return TouchpadCalibration(
                swapAxes: false,
                invertX: rightX < 0,
                invertY: downY < 0
            )
        }
        if !downDominantY && !rightDominantX {
            // Axes swapped: raw X axis carries screen-Y motion,
            // raw Y axis carries screen-X motion.
            return TouchpadCalibration(
                swapAxes: true,
                invertX: rightY < 0,
                invertY: downX < 0
            )
        }
        // Both gestures dominant on the same axis (or each ambiguous):
        // the user's calibration was inconsistent. Caller should retry.
        return nil
    }
}

extension TouchpadCalibration {
    /// UserDefaults key. The `.v2` suffix matters: v34 (`.v1`) stored a
    /// 4-float basis-matrix that we no longer interpret correctly.
    /// Reading `.v1` now would map a stale matrix into nonsense bool
    /// fields, so we ignore the old key entirely. Any v34 user will
    /// simply launch v35 with identity calibration and re-run the flow.
    private static let defaultsKey = "iRemote.touchpadCalibration.v2"

    static func loadFromDefaults() -> TouchpadCalibration {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: defaultsKey),
              let swap = dict["swapAxes"] as? Bool,
              let invX = dict["invertX"] as? Bool,
              let invY = dict["invertY"] as? Bool else {
            return .identity
        }
        return TouchpadCalibration(swapAxes: swap, invertX: invX, invertY: invY)
    }

    func saveToDefaults() {
        let dict: [String: Bool] = [
            "swapAxes": swapAxes,
            "invertX":  invertX,
            "invertY":  invertY,
        ]
        UserDefaults.standard.set(dict, forKey: Self.defaultsKey)
    }

    static func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        // Also wipe v34's stale matrix key if it still exists, so it
        // can't leak back in via someone hand-importing defaults.
        UserDefaults.standard.removeObject(forKey: "iRemote.touchpadCalibration.v1")
    }
}
