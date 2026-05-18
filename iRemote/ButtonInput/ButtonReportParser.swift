import Foundation

/// Maps an HID parsed input value to a human-readable button name.
/// Real-world Siri Remote 1st-gen mappings are confirmed empirically in Phase 1.
/// This parser is intentionally permissive: unknown usages are surfaced
/// (rather than dropped) so the menu reveals what the device is actually
/// emitting on this firmware/macOS combination.
enum ButtonReportParser {
    static func parse(usagePage: UInt32, usage: UInt32, value: CFIndex) -> String? {
        let pressed = value > 0
        let edge = pressed ? "↓" : "↑"

        switch usagePage {
        case 0x0C: // Consumer
            return "\(consumerName(usage)) \(edge)"

        case 0x09: // Button
            return "Btn \(usage) \(edge)"

        case 0x01: // Generic Desktop (X/Y axes — touchpad)
            // Stay quiet on continuous axis spam; surface only edge-ish movements.
            // Phase 1 doesn't need touchpad gestures.
            return nil

        case 0x07: // Keyboard
            return "Key 0x\(String(usage, radix: 16)) \(edge)"

        default:
            // Unknown — surface for diagnosis. Drop touchpad-axis spam by
            // ignoring values inside ±1 on probable analog ranges.
            if abs(value) <= 1, usagePage > 0xFFFF { return nil }
            return String(format: "UP=0x%X U=0x%X v=%d", usagePage, usage, value)
        }
    }

    private static func consumerName(_ usage: UInt32) -> String {
        // Standard HID Consumer Page usages most likely to appear from Siri Remote.
        // Some Apple-private mappings show up here too; unknowns get hex.
        switch usage {
        case 0x0040: return "Menu"
        case 0x00B0: return "Play"
        case 0x00B1: return "Pause"
        case 0x00CD: return "Play/Pause"
        case 0x00E9: return "Volume +"
        case 0x00EA: return "Volume −"
        case 0x0221: return "Search/Siri"
        case 0x0223: return "Home"
        case 0x029D: return "AC AppCntl Cfg"
        default:     return String(format: "Cons 0x%04X", usage)
        }
    }
}
