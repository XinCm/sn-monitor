import AppKit

/// Small area chart drawn with NSBezierPath. Redrawn only when the data or the
/// row is refreshed, which happens once per sampling tick.
final class SparklineView: NSView {
    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var range: ClosedRange<Double> = 0...100 {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1, bounds.width > 2, bounds.height > 2 else { return }

        let low = range.lowerBound
        let high = max(range.upperBound, low + 0.0001)
        let inset: CGFloat = 1
        let width = bounds.width - inset * 2
        let height = bounds.height - inset * 2

        func point(_ index: Int, _ value: Double) -> NSPoint {
            let x = inset + width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = min(1, max(0, (value - low) / (high - low)))
            let y = inset + height * (1 - CGFloat(normalized))
            return NSPoint(x: x, y: y)
        }

        let line = NSBezierPath()
        line.lineWidth = 1.4
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        for index in values.indices {
            let p = point(index, values[index])
            if index == 0 { line.move(to: p) } else { line.line(to: p) }
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: inset, y: bounds.height - inset))
        for index in values.indices {
            fill.line(to: point(index, values[index]))
        }
        fill.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        fill.close()

        color.withAlphaComponent(0.12).setFill()
        fill.fill()
        color.setStroke()
        line.stroke()
    }
}
