import AppKit

// The Mac's look, read on the main thread: light or dark, and the accent.
struct Look {
    var name: String          // "Dark · Blue"
    var accentIndex: Int      // into Palette.swatchNames
    var dark: Bool
}

// The window's colours, from the system's: the accent, one colour per
// section, and macOS's 8 accent colours for the Look ring. They follow
// light and dark mode and the accent chosen in System Settings.
enum Palette {
    static let swatchNames = ["Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Graphite"]
    static let swatchColors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemGray]

    static func look() -> Look {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // AppleAccentColor: missing = multicolour (blue), -1 graphite, 0 red … 6 pink.
        let raw = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleAccentColor"] as? Int
        let index: Int
        switch raw {
        case nil: index = 0
        case -1: index = 7
        case 0: index = 3
        case 1: index = 4
        case 2: index = 5
        case 3: index = 6
        case 4: index = 0
        case 5: index = 1
        case 6: index = 2
        default: index = 0
        }
        let accent = raw == nil ? "Multicolor" : swatchNames[index]
        return Look(name: (dark ? "Dark" : "Light") + " · " + accent, accentIndex: index, dark: dark)
    }

    static func background(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.975, alpha: 1)
    }

    static func current() -> [String: Any] {
        let dark = look().dark
        var out: [String: Any] = [:]
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            out = [
                "bg": hex(background(dark: dark)),
                "fg": dark ? "#d7dae0" : "#23252b",
                "accent": hex(.controlAccentColor),
                "hw": hex(.systemBlue),
                "sw": hex(dark ? .systemYellow : .systemOrange),
                "age": hex(.systemPink),
                "swatches": swatchColors.map { hex($0) },
            ]
        }
        return out
    }

    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#888888" }
        let v = [s.redComponent, s.greenComponent, s.blueComponent].map { Int(round(max(0, min(1, $0)) * 255)) }
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2])
    }
}
