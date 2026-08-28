import SwiftUI

enum RecBarColor {
    /// Warm, saturated red — not a garish pure #FF0000.
    static let red = Color(red: 0xD6 / 255.0, green: 0x28 / 255.0, blue: 0x39 / 255.0)
    /// Apple's own system green (#34C759) — used for the menu bar icon while actively
    /// recording, distinct from `red` (paused) and orange (watchdog prompt).
    static let green = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
}
