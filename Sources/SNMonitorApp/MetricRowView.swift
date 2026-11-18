import AppKit

/// One metric block: title, big value, sparkline, subtitle.
final class MetricRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let sparkline = SparklineView()

    override var isFlipped: Bool { true }

    init(title: String, color: NSColor) {
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.truncatesLastVisibleLine = true

        sparkline.color = color

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(sparkline)
        addSubview(subtitleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: String, subtitle: String, values: [Double], range: ClosedRange<Double>) {
        valueLabel.stringValue = value
        subtitleLabel.stringValue = subtitle
        sparkline.values = values
        sparkline.range = range
    }

    func setSubtitleColor(_ color: NSColor) {
        subtitleLabel.textColor = color
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 0, y: 0, width: width * 0.55, height: 14)
        valueLabel.frame = NSRect(x: width * 0.45, y: -4, width: width * 0.55, height: 26)
        sparkline.frame = NSRect(x: 0, y: 22, width: width, height: 18)
        subtitleLabel.frame = NSRect(x: 0, y: 44, width: width, height: 14)
    }
}
