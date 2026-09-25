import AppKit

/// The menu-bar mark: the app icon's ring and arc, drawn as a template image so AppKit
/// recolours it for light, dark and highlighted menu bars. A template is one colour, so
/// the ring is drawn faint and the arc solid — alpha stands in for the icon's green.
/// Geometry is expressed as fractions of the side, taken from `Resources/AppIcon.png`,
/// so the same code renders the 16 pt item and any @2x representation.
enum StatusItemGlyph {
    private enum Ratio {
        static let ringOuterRadius: CGFloat = 0.44
        static let ringThickness: CGFloat = 0.15
        static let ringAlpha: CGFloat = 0.35
    }

    /// Arc end points, in degrees counter-clockwise from 3 o'clock, as on the app icon.
    private static let arcStart: CGFloat = 57
    private static let arcEnd: CGFloat = -36

    static func make(side: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(side: side)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(side: CGFloat) {
        let center = CGPoint(x: side / 2, y: side / 2)
        let thickness = side * Ratio.ringThickness
        let radius = side * Ratio.ringOuterRadius - thickness / 2

        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        ring.lineWidth = thickness
        NSColor.black.withAlphaComponent(Ratio.ringAlpha).setStroke()
        ring.stroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center, radius: radius,
            startAngle: arcStart, endAngle: arcEnd, clockwise: true
        )
        arc.lineWidth = thickness
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }
}
