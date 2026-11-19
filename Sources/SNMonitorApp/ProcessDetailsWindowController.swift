import AppKit
import SNMonitorCore

/// A compact two-column list of the top processes by CPU and by memory.
final class ProcessListView: NSView {
    var items: [ProcessUsage] = [] {
        didSet { needsDisplay = true }
    }

    var sort: ProcessSort = .cpu {
        didSet { needsDisplay = true }
    }

    var cpuReady = true {
        didSet { needsDisplay = true }
    }

    var emptyMessage = "采样中…" {
        didSet { needsDisplay = true }
    }

    private let rowHeight: CGFloat = 26
    private let headerHeight: CGFloat = 24
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    private let nameFont = NSFont.systemFont(ofSize: 12)
    private let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let headerFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawText("PID", rect: NSRect(x: 16, y: 4, width: 40, height: 14),
                 font: headerFont, color: .secondaryLabelColor, alignment: .right)
        drawText("进程", rect: NSRect(x: 60, y: 4, width: 126, height: 14),
                 font: headerFont, color: .secondaryLabelColor)
        drawText("CPU", rect: NSRect(x: 190, y: 4, width: 52, height: 14),
                 font: headerFont,
                 color: sort == .cpu ? .controlAccentColor : .secondaryLabelColor,
                 alignment: .right)
        drawText("内存", rect: NSRect(x: 246, y: 4, width: 62, height: 14),
                 font: headerFont,
                 color: sort == .memory ? .controlAccentColor : .secondaryLabelColor,
                 alignment: .right)

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: 0, y: headerHeight - 0.5))
        line.line(to: NSPoint(x: bounds.width, y: headerHeight - 0.5))
        line.stroke()

        guard !items.isEmpty else {
            drawText(emptyMessage, rect: NSRect(x: 0, y: headerHeight + 24, width: bounds.width, height: 18),
                     font: nameFont, color: .tertiaryLabelColor, alignment: .center)
            return
        }

        for (index, item) in items.prefix(10).enumerated() {
            let y = headerHeight + CGFloat(index) * rowHeight
            if index.isMultiple(of: 2) {
                NSColor.separatorColor.withAlphaComponent(0.06).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }

            drawText("\(index + 1)", rect: NSRect(x: 0, y: y + 7, width: 12, height: 14),
                     font: smallFont, color: .tertiaryLabelColor, alignment: .right)
            drawText(String(item.pid), rect: NSRect(x: 16, y: y + 6, width: 40, height: 14),
                     font: smallFont, color: .tertiaryLabelColor, alignment: .right)
            drawText(item.name, rect: NSRect(x: 60, y: y + 5, width: 126, height: 16),
                     font: nameFont, color: .labelColor, truncating: true)
            let cpu = cpuReady ? String(format: "%.1f%%", item.cpuPercent) : "—"
            drawText(cpu, rect: NSRect(x: 190, y: y + 6, width: 52, height: 14),
                     font: valueFont,
                     color: sort == .cpu && cpuReady ? .labelColor : .secondaryLabelColor,
                     alignment: .right)
            drawText(Format.bytes(item.memoryBytes),
                     rect: NSRect(x: 246, y: y + 6, width: 62, height: 14),
                     font: valueFont,
                     color: sort == .memory ? .labelColor : .secondaryLabelColor,
                     alignment: .right)
        }
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        truncating: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = truncating ? .byTruncatingTail : .byClipping
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}

final class ProcessDetailsViewController: NSViewController {
    var onIntervalChange: ((TimeInterval) -> Void)?

    private let cpuTitle = NSTextField(labelWithString: "CPU 占用 Top 10")
    private let memoryTitle = NSTextField(labelWithString: "内存占用 Top 10")
    private let cpuList = ProcessListView()
    private let memoryList = ProcessListView()
    private let footer = NSTextField(labelWithString: "")
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var interval: TimeInterval = 2

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 680, height: 364))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for title in [cpuTitle, memoryTitle] {
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            root.addSubview(title)
        }

        cpuList.sort = .cpu
        memoryList.sort = .memory
        root.addSubview(cpuList)
        root.addSubview(memoryList)

        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        root.addSubview(footer)

        intervalPopup.addItems(withTitles: ["1 秒", "2 秒", "5 秒"])
        for (index, value) in [1.0, 2.0, 5.0].enumerated() {
            intervalPopup.item(at: index)?.tag = Int(value)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged(_:))
        intervalPopup.controlSize = .small
        intervalPopup.font = .systemFont(ofSize: 10.5)
        root.addSubview(intervalPopup)

        self.view = root
        setInterval(interval)
        markSampling()
    }

    func setInterval(_ interval: TimeInterval) {
        self.interval = interval
        intervalPopup.selectItem(withTag: Int(interval))
        updateFooter()
    }

    func update(_ sample: ProcessSample) {
        cpuList.cpuReady = sample.cpuReady
        memoryList.cpuReady = sample.cpuReady
        cpuList.emptyMessage = "等待 CPU 差值…"
        cpuList.items = sample.cpuReady
            ? ProcessSampler.top(sample.usages, by: .cpu, limit: 10)
            : []
        memoryList.items = ProcessSampler.top(sample.usages, by: .memory, limit: 10)
        updateFooter()
    }

    func markSampling() {
        cpuList.cpuReady = false
        memoryList.cpuReady = false
        cpuList.emptyMessage = "正在采样…"
        memoryList.emptyMessage = "正在采样…"
        cpuList.items = []
        memoryList.items = []
        updateFooter()
    }

    func showStale() {
        cpuList.cpuReady = false
        memoryList.cpuReady = false
        cpuList.emptyMessage = "采样失败，数据可能已过期"
        memoryList.emptyMessage = "采样失败，数据可能已过期"
        cpuList.items = []
        memoryList.items = []
        footer.stringValue = "采样失败 · 数据可能已过期"
        footer.textColor = .systemOrange
    }

    private func updateFooter() {
        footer.textColor = .tertiaryLabelColor
        footer.stringValue = "每 \(Int(interval)) 秒更新 · CPU 100% = 一个核心 · 内存为 footprint"
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        onIntervalChange?(TimeInterval(sender.selectedTag()))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let margin: CGFloat = 20
        let columnWidth: CGFloat = 310
        let listTop: CGFloat = 40
        let listHeight: CGFloat = 284

        cpuTitle.frame = NSRect(x: margin, y: 16, width: columnWidth, height: 18)
        memoryTitle.frame = NSRect(x: margin + columnWidth + 20, y: 16, width: columnWidth, height: 18)
        cpuList.frame = NSRect(x: margin, y: listTop, width: columnWidth, height: listHeight)
        memoryList.frame = NSRect(x: margin + columnWidth + 20, y: listTop, width: columnWidth, height: listHeight)
        footer.frame = NSRect(x: margin, y: 334, width: 540, height: 14)
        intervalPopup.frame = NSRect(x: 596, y: 328, width: 64, height: 24)
    }
}

final class ProcessDetailsWindowController: NSWindowController, NSWindowDelegate {
    private let details = ProcessDetailsViewController()
    private var sampler: ProcessSampler?
    private var interval: TimeInterval = 2

    init() {
        let saved = UserDefaults.standard.double(forKey: "detailsInterval")
        if saved == 1 || saved == 2 || saved == 5 {
            interval = saved
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 364),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "进程详情"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.contentViewController = details
        window.delegate = self

        details.onIntervalChange = { [weak self] newInterval in
            self?.changeInterval(newInterval)
        }
        details.setInterval(interval)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startSampling()
    }

    func stopSampling() {
        sampler?.onSample = nil
        sampler?.onError = nil
        sampler?.stop()
        sampler = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopSampling()
    }

    func snapshot(to path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("process snapshot: \(path)")
        fflush(stdout)
    }

    private func changeInterval(_ newInterval: TimeInterval) {
        guard newInterval != interval else { return }
        interval = newInterval
        UserDefaults.standard.set(newInterval, forKey: "detailsInterval")
        details.setInterval(newInterval)
        startSampling()
    }

    private func startSampling() {
        stopSampling()
        details.markSampling()

        let sampler = ProcessSampler()
        sampler.onSample = { [weak self] sample in
            self?.details.update(sample)
        }
        sampler.onError = { [weak self] in
            self?.details.showStale()
        }
        self.sampler = sampler
        sampler.start(interval: interval)
    }
}
