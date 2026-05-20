import AppKit

final class ProgressBarView: NSView {
    var value: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var fillColor: NSColor = .systemBlue {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let clamped = min(1, max(0, value))
        let rect = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - 8) / 2))
        let radius = rect.height / 2

        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard clamped > 0 else {
            return
        }

        let fillRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: max(rect.height, rect.width * clamped),
            height: rect.height
        )
        fillColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

enum ProgressBarImageRenderer {
    static func image(value: Double, color: NSColor, size: NSSize = NSSize(width: 46, height: 10)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 0, y: 2, width: size.width, height: 6)
        let radius = rect.height / 2
        let clamped = min(1, max(0, value))

        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        if clamped > 0 {
            let fillRect = NSRect(
                x: rect.minX,
                y: rect.minY,
                width: max(rect.height, rect.width * clamped),
                height: rect.height
            )
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
