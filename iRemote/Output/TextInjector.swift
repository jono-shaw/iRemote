import AppKit
import CoreGraphics

/// Posts Unicode keystrokes to the focused application via CGEvent.
/// Requires the user to grant Accessibility permission to iRemote.app
/// (System Settings → Privacy & Security → Accessibility).
///
/// We don't need a "real" virtual key code — Apple lets us just set the
/// Unicode string on a synthetic keydown/keyup event, which works for
/// arbitrary text input across most Cocoa apps.
final class TextInjector {
    private let source: CGEventSource?

    init() {
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// True if Accessibility permission appears to be granted.
    func hasAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Prompts the user to grant Accessibility permission (one-time, system UI).
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Inject `text` into the focused app. Clipboard paste is more reliable
    /// than synthetic Unicode key chunks.
    @discardableResult
    func inject(_ text: String, charDelayMicros: useconds_t = 1500) -> Bool {
        guard hasAccessibility() else { return false }
        if pasteViaClipboard(text) { return true }

        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let end = min(i + 20, utf16.count)
            let chunk = Array(utf16[i..<end])
            postUTF16Chunk(chunk)
            usleep(charDelayMicros)
            i = end
        }
        return true
    }

    private func pasteViaClipboard(_ text: String) -> Bool {
        guard source != nil else { return false }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard postCommandV() else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.string(forType: .string) == text else { return }
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }

    private func postCommandV() -> Bool {
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private func postUTF16Chunk(_ chunk: [UniChar]) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        var local = chunk
        down?.keyboardSetUnicodeString(stringLength: local.count, unicodeString: &local)
        up?.keyboardSetUnicodeString(stringLength: local.count, unicodeString: &local)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
