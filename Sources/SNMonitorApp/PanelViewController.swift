import AppKit
import SNMonitorCore

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The popover panel with five live metric rows.
final class PanelViewController: NSViewController {
    var onSettings: ((NSView) -> Void)?
    var onQuit: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "sn-monitor")
    private let intervalLabel = NSTextField(labelWithString: "1s")
    private let versionLabel = NSTextField(labelWithString: "v0.1.1")
    private var rows: [MetricRowView] = []

    override func loadView() {
        let panel = FlippedView(frame: NSRect(x: 0, y: 0, width: 320, height: 404))
        panel.wantsLayer = true

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        intervalLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        intervalLabel.textColor = .secondaryLabelColor
        intervalLabel.alignment = .right
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor

        panel.addSubview(headerLabel)
        panel.addSubview(intervalLabel)
        panel.addSubview(versionLabel)

        let definitions: [(String, NSColor)] = [
            ("CPU", .systemBlue),
            ("内存", .systemPurple),
            ("磁盘", .systemTeal),
            ("刷新率", .systemIndigo),
            ("温度", .systemOrange),
        ]

        var y: CGFloat = 40
        for (title, color) in definitions {
            let row = MetricRowView(title: title, color: color)
            row.frame = NSRect(x: 12, y: y, width: 296, height: 62)
            panel.addSubview(row)
            rows.append(row)
            y += 64
        }

        let separator = NSView(frame: NSRect(x: 12, y: 366, width: 296, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        panel.addSubview(separator)

        let settingsButton = makeIconButton(symbol: "gearshape", action: #selector(settingsPressed(_:)))
        let quitButton = makeIconButton(symbol: "power", action: #selector(quitPressed))
        panel.addSubview(settingsButton)
        panel.addSubview(quitButton)
        settingsButton.frame = NSRect(x: 260, y: 374, width: 18, height: 18)
        quitButton.frame = NSRect(x: 290, y: 374, width: 18, height: 18)

        self.view = panel
    }

    func update(_ snapshot: Snapshot, history: HistoryStore, interval: TimeInterval) {
        if !isViewLoaded { _ = view }
        guard rows.count == 5 else { return }

        intervalLabel.stringValue = Self.intervalText(interval)

        let cpu = snapshot.cpu
        rows[0].update(
            value: Format.percent(cpu.usage),
            subtitle: String(
                format: "用户 %.0f%% · 系统 %.0f%% · 负载 %.2f",
                cpu.user * 100, cpu.system * 100, cpu.loadAverage1
            ),
            values: history.cpu,
            range: 0...100
        )
        rows[0].setSubtitleColor(.secondaryLabelColor)

        let memory = snapshot.memory
        rows[1].update(
            value: Format.percent(memory.usage),
            subtitle: "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total))"
                + " · 交换 \(Format.bytes(memory.swapUsed))"
                + " · 压力 \(memory.pressure.label)",
            values: history.memory,
            range: 0...100
        )
        switch memory.pressure {
        case .warning: rows[1].setSubtitleColor(.systemOrange)
        case .critical: rows[1].setSubtitleColor(.systemRed)
        default: rows[1].setSubtitleColor(.secondaryLabelColor)
        }

        let disk = snapshot.disk
        let totalRate = disk.readBytesPerSecond + disk.writeBytesPerSecond
        rows[2].update(
            value: Format.rate(totalRate),
            subtitle: "读 \(Format.rate(disk.readBytesPerSecond))"
                + " · 写 \(Format.rate(disk.writeBytesPerSecond))"
                + " · 可用 \(Format.diskBytes(disk.free))",
            values: history.disk,
            range: 0...max(1, (history.disk.max() ?? 1) * 1.2)
        )
        rows[2].setSubtitleColor(.secondaryLabelColor)

        let display = snapshot.display
        rows[3].update(
            value: display.refreshRate > 0 ? String(format: "%.0f Hz", display.refreshRate) : "—",
            subtitle: "\(display.pixelWidth) × \(display.pixelHeight) · \(display.name)",
            values: history.refresh,
            range: 0...144
        )
        rows[3].setSubtitleColor(.secondaryLabelColor)

        let thermal = snapshot.thermal
        var thermalSubtitle = "GPU \(Format.temperature(thermal.gpuCelsius))"
            + " · 电池 \(Format.temperature(thermal.batteryCelsius))"
        if !thermal.isAvailable {
            thermalSubtitle = "SMC 不可用"
        }
        rows[4].update(
            value: Format.temperature(thermal.cpuCelsius),
            subtitle: thermalSubtitle,
            values: history.temperature,
            range: 20...110
        )
        rows[4].setSubtitleColor(.secondaryLabelColor)
    }

    func setMenuBarHint(_ hidden: Bool) {
        versionLabel.stringValue = hidden ? "菜单栏已满 · ⌃⌥M" : "v0.1.1"
        versionLabel.textColor = hidden ? .systemOrange : .tertiaryLabelColor
    }

    static func intervalText(_ interval: TimeInterval) -> String {
        interval >= 1 ? String(format: "%.0fs", interval) : String(format: "%.1fs", interval)
    }

    private func makeIconButton(symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = symbol == "power" ? "退出" : "设置"
        return button
    }

    @objc private func settingsPressed(_ sender: NSButton) {
        onSettings?(sender)
    }

    @objc private func quitPressed() {
        onQuit?()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        headerLabel.frame = NSRect(x: 12, y: 12, width: 200, height: 18)
        intervalLabel.frame = NSRect(x: 240, y: 13, width: 68, height: 16)
        versionLabel.frame = NSRect(x: 12, y: 376, width: 170, height: 14)
    }
}
