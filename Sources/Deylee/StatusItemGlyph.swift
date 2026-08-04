import AppKit

/// The menu-bar clock mark, drawn as a template image so AppKit recolours it for
/// light, dark and highlighted menu bars. Geometry is expressed as fractions of the
/// side so the same code renders the 16 pt item and any @2x representation.
enum StatusItemGlyph {
    private enum Ratio {
        static let ringOuterRadius: CGFloat = 0.42
        static let ringThickness: CGFloat = 0.1
        static let minuteHandLength: CGFloat = 0.225
        static let hourHandLength: CGFloat = 0.17
        static let handHalfWidth: CGFloat = 0.042
    }

    static func make(side: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(side: side)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(side: CGFloat) {
        NSColor.black.setFill()
        let center = CGPoint(x: side / 2, y: side / 2)

        let outer = side * Ratio.ringOuterRadius
        let inner = outer - side * Ratio.ringThickness
        let ring = NSBezierPath(ovalIn: NSRect(
            x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2
        ))
        ring.append(NSBezierPath(ovalIn: NSRect(
            x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2
        )))
        ring.windingRule = .evenOdd
        ring.fill()

        let halfWidth = side * Ratio.handHalfWidth
        // Minute hand points straight up, hour hand to the right — a fixed, legible
        // pose rather than the real time, which would be unreadable at 16 pt.
        capsule(
            from: center,
            to: CGPoint(x: center.x, y: center.y + side * Ratio.minuteHandLength),
            halfWidth: halfWidth
        ).fill()
        capsule(
            from: center,
            to: CGPoint(x: center.x + side * Ratio.hourHandLength, y: center.y),
            halfWidth: halfWidth
        ).fill()
    }

    private static func capsule(from: CGPoint, to: CGPoint, halfWidth: CGFloat) -> NSBezierPath {
        let rect = NSRect(
            x: min(from.x, to.x) - halfWidth,
            y: min(from.y, to.y) - halfWidth,
            width: abs(to.x - from.x) + halfWidth * 2,
            height: abs(to.y - from.y) + halfWidth * 2
        )
        return NSBezierPath(roundedRect: rect, xRadius: halfWidth, yRadius: halfWidth)
    }
}
