import Cocoa
import CoreGraphics

/// Listens for media-key events (Volume +, Volume −, Play/Pause) posted
/// by bluetoothd from the paired Siri Remote (these are the only buttons
/// macOS routes to system events for the 1st gen remote on macOS 26).
///
/// Use as a PTT trigger: press Vol+ to start, release to stop. Optionally
/// suppress the underlying volume change so the user can use Vol+ as PTT
/// without changing system volume.
final class MediaKeyTap {
    enum Key { case volumeUp, volumeDown, playPause }
    enum Phase { case down, up }

    let onEvent: (Key, Phase) -> Void
    let suppressVolume: Bool

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(suppressVolume: Bool = false, onEvent: @escaping (Key, Phase) -> Void) {
        self.suppressVolume = suppressVolume
        self.onEvent = onEvent
    }

    /// Returns false if Accessibility permission is missing.
    func start() -> Bool {
        // CGEventType doesn't have .systemDefined; raw value 14 = NX_SYSDEFINED
        let kSystemDefinedRaw: UInt32 = 14
        let mask: CGEventMask = (1 << kSystemDefinedRaw)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, ctx in
                guard let ctx = ctx else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<MediaKeyTap>.fromOpaque(ctx).takeUnretainedValue()
                return me.handle(event)
            },
            userInfo: selfPtr
        )
        guard let tap else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        // System-defined event subtype 8 = aux key (media keys).
        // bit pattern in data1: keyCode in upper 16 bits, state flags in lower
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA  // 0xA = key down, 0xB = key up

        let key: Key?
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP_INT:   key = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN_INT: key = .volumeDown
        case NX_KEYTYPE_PLAY_INT:        key = .playPause
        default: key = nil
        }
        guard let key else { return Unmanaged.passUnretained(event) }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent(key, isDown ? .down : .up)
        }

        if suppressVolume, key != .playPause {
            return nil   // swallow the event so system volume doesn't change
        }
        return Unmanaged.passUnretained(event)
    }
}

// NX_KEYTYPE_* are private in <IOKit/hidsystem/ev_keymap.h>; replicate here.
private let NX_KEYTYPE_SOUND_UP_INT: Int   = 0
private let NX_KEYTYPE_SOUND_DOWN_INT: Int = 1
private let NX_KEYTYPE_PLAY_INT: Int       = 16
