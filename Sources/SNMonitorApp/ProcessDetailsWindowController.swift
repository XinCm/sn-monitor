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

    private let rowHeight: CGFloat = 26
    private let headerHeight: CGFloat = 24
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    private let nameFont = NSFont.systemFont(ofSize: 12)
    private let rankFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let headerFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawText("进程", rect: NSRect(x: 20, y: 4, width: 150, height: 14), font: headerFont, color: .secondaryLabelColor)
        drawText("CPU", rect: NSRect(x: 176, y: 4, width: 58, height: 14), font: headerFont,
                 color: sort == .cpu ? .controlAccentColor : .secondaryLabelColor, alignment: .right)
        drawText("内存", rect: NSRect(x: 240, y: 4, width: 68, height: 14), font: headerFont,
                 color: sort == .memory ? .controlAccentColor : .secondaryLabelColor, alignment: .right)

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: 0, y: headerHeight - 0.5))
        line.line(to: NSPoint(x: bounds.width, y: headerHeight - 0.5))
        line.stroke()

        guard !items.isEmpty else {
            drawText("采样中…", rect: NSRect(x: 0, y: headerHeight + 24, width: bounds.width, height: 18),
                     font: nameFont, color: .tertiaryLabelColor, alignment: .center)
            return
        }

        for (index, item) in items.prefix(10).enumerated() {
            let y = headerHeight + CGFloat(index) * rowHeight
            if index.isMultiple(of: 2) {
                NSColor.separatorColor.withAlphaComponent(0.06).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }

            drawText("\(index + 1)", rect: NSRect(x: 0, y: y + 6, width: 16, height: 14),
                     font: rankFont, color: .tertiaryLabelColor, alignment: .right)
            drawText(item.name, rect: NSRect(x: 20, y: y + 5, width: 150, height: 16),
                     font: nameFont, color: .labelColor, truncating: true)
            drawText(String(format: "%.1f%%", item.cpuPercent),
                     rect: NSRect(x: 176, y: y + 6, width: 58, height: 14),
                     font: valueFont,
                     color: sort == .cpu ? .labelColor : .secondaryLabelColor,
                     alignment: .right)
            drawText(Format.bytes(item.memoryBytes),
                     rect: NSRect(x: 240, y: y + 6, width: 68, height: 14),
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
    private let cpuTitle = NSTextField(labelWithString: "CPU 占用 Top 10")
    private let memoryTitle = NSTextField(labelWithString: "内存占用 Top 10")
    private let cpuList = ProcessListView()
    private let memoryList = ProcessListView()
    private let footer = NSTextField(labelWithString: "每秒刷新 · 内存为 RSS 驻留集")

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

        self.view = root
    }

    func update(_ usages: [ProcessUsage]) {
        cpuList.items = ProcessSampler.top(usages, by: .cpu, limit: 10)
        memoryList.items = ProcessSampler.top(usages, by: .memory, limit: 10)
        footer.stringValue = "每秒刷新 · 内存为 RSS 驻留集 · "
            + Date().formatted(date: .omitted, time: .standard)
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
        footer.frame = NSRect(x: margin, y: 334, width: 640, height: 14)
    }
}

final class ProcessDetailsWindowController: NSWindowController, NSWindowDelegate {
    private let details = ProcessDetailsViewController()
    private let sampler = ProcessSampler()
    private let queue = DispatchQueue(label: "com.sean.snmonitor.processes", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var running = false

    init() {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        start()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
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

    private func start() {
        guard !running else { return }
        running = true
        sampler.reset()

        queue.async { [weak self] in
            guard let self else { return }
            let usages = self.sampler.sample()
            self.publish(usages)
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let usages = self.sampler.sample()
            self.publish(usages)
        }
        source.resume()
        timer = source
    }

    private func publish(_ usages: [ProcessUsage]) {
        DispatchQueue.main.async { [weak self] in
            self?.details.update(usages)
        }
    }

    private func stop() {
        running = false
        timer?.cancel()
        timer = nil
    }
}
