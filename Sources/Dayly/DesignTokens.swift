import SwiftUI

/// The palette from docs/DESIGN.md, resolved per appearance.
///
/// Dark is the primary theme. Two rules the rest of the UI depends on:
///  - `work` green is reserved exclusively for the running/work state.
///  - `accent` is a NEUTRAL — near-black in light, near-white in dark — so a
///    primary button never competes with the running indicator.
///
/// Never write a literal colour anywhere else; add a token here instead.
enum Palette {
    /// Window base.
    static let surface = pair(light: 0xf2f2ef, dark: 0x141416)
    /// Card and panel fill.
    static let raised = pair(light: 0xffffff, dark: 0x232326)
    /// Recessed fill — progress tracks, modal footers.
    static let sunken = pair(light: 0xf7f7f5, dark: 0x18181b)
    static let hover = pair(light: 0xececea, dark: 0x2e2e33)
    static let border = pair(light: 0xe0e0dc, dark: 0x35353a)
    /// Strong border, default focus ring, scrollbar thumb.
    static let borderStrong = pair(light: 0xd8d8d4, dark: 0x47474e)

    static let fg = pair(light: 0x1c1c1e, dark: 0xebebef)
    static let fgMuted = pair(light: 0x6b6b70, dark: 0xa0a0a8)
    /// Tertiary text and caps labels.
    static let fgFaint = pair(light: 0x98989e, dark: 0x6e6e76)
    /// The hero's trailing seconds.
    static let fgDim = pair(light: 0x8e8e94, dark: 0x8b8b93)
    /// Disabled numerals.
    static let fgGhost = pair(light: 0xc2c2c6, dark: 0x4a4a52)

    static let accent = pair(light: 0x1c1c1e, dark: 0xebebef)
    static let accentHover = pair(light: 0x33333a, dark: 0xffffff)
    /// Label drawn on top of `accent`.
    static let accentFg = pair(light: 0xffffff, dark: 0x18181a)
    /// Selection background and selected calendar cells.
    static let accentSoft = pair(light: 0xececea, dark: 0x2e2e33)

    static let work = pair(light: 0x2f8a72, dark: 0x4fbfa0)
    static let workSoft = pair(light: 0x2f8a72, lightAlpha: 0.14, dark: 0x4fbfa0, darkAlpha: 0.16)
    static let breakColor = pair(light: 0x8c6a2a, dark: 0xc79a54)
    static let breakSoft = pair(light: 0x8c6a2a, lightAlpha: 0.14, dark: 0xc79a54, darkAlpha: 0.16)

    static let danger = pair(light: 0xc0392b, dark: 0xe05c53)
    static let dangerSoft = pair(light: 0xc0392b, lightAlpha: 0.12, dark: 0xe05c53, darkAlpha: 0.16)

    private static func pair(
        light: UInt32, lightAlpha: Double = 1,
        dark: UInt32, darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

/// The type ramp. Everything that ticks or stacks uses tabular figures so digits
/// never shift the layout as they change.
enum Type {
    /// Panel hero — 52 pt, weight 300, tight tracking.
    static let hero = Font.system(size: 52, weight: .light).monospacedDigit()
    /// The hero's trailing `:SS`, half the hero size.
    static let heroSeconds = Font.system(size: 26, weight: .light).monospacedDigit()
    /// History day hero.
    static let dayHero = Font.system(size: 38, weight: .light).monospacedDigit()
    /// Mini window timer — H:MM, no seconds.
    static let miniTimer = Font.system(size: 22, weight: .regular).monospacedDigit()
    static let monthTitle = Font.system(size: 17, weight: .medium)
    static let statValue = Font.system(size: 15, weight: .medium).monospacedDigit()
    static let body = Font.system(size: 13)
    static let control = Font.system(size: 14)
    static let controlLarge = Font.system(size: 15)
    static let small = Font.system(size: 12)
    static let meta = Font.system(size: 11)
    static let metaTabular = Font.system(size: 11).monospacedDigit()
    /// Uppercase section labels — `Today`, and the settings group headings.
    static let caps = Font.system(size: 10, weight: .medium)
}

/// 4 px grid. Only the steps the design actually uses.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 14
    static let x3l: CGFloat = 16
    static let x4l: CGFloat = 20
    static let x5l: CGFloat = 24
    static let x6l: CGFloat = 40
}

enum Radius {
    /// Window, panel and modal.
    static let window: CGFloat = 10
    /// Buttons, rows and inputs.
    static let control: CGFloat = 8
    /// Chips, steppers and small icons.
    static let chip: CGFloat = 6
    /// Settings cards and the mini card.
    static let card: CGFloat = 12
}

/// Deliberately minimal: no scale transforms, no bounce, no pulsing, no sound.
enum Motion {
    /// Every interactive control's colour transition.
    static let control = Animation.easeOut(duration: 0.15)
    /// The target progress bar's width and colour.
    static let progress = Animation.easeOut(duration: 0.5)
}

enum Layout {
    static let panelSize = CGSize(width: 320, height: 436)
    static let miniSize = CGSize(width: 180, height: 56)
    static let historySize = CGSize(width: 900, height: 640)
    static let historyMinSize = CGSize(width: 760, height: 520)
    static let settingsSize = CGSize(width: 560, height: 640)
    static let settingsMinSize = CGSize(width: 480, height: 420)
    /// Gap between the status item and the top of the panel.
    static let panelStatusItemGap: CGFloat = 8
    /// Inset from the work-area corner where a mini window first appears.
    static let miniDefaultInset: CGFloat = 24
}
