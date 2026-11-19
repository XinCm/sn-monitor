import AppKit
import SNMonitorCore
import Carbon
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum MenuBarContent: String {
    case cpuMemoryTemp
    case cpuMemory
    case cpuTemp
    case cpuOnly
    case iconOnly

    var label: String {
        switch self {
        case .cpuMemoryTemp: return "CPU + 内存 + 温度"
        case .cpuMemory: return "CPU + 内存"
        case .cpuTemp: return "CPU + 温度"
        case .cpuOnly: return "仅 CPU"
        case .iconOnly: return "仅图标"
        }
    }
}

private let showPanelNotification = Notification.Name("com.sean.snmonitor.showPanel")

private func hotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.togglePopover()
    }
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panel: PanelViewController!
    private var engine: MetricsEngine!
    private let history = HistoryStore()
    private var latest: Snapshot?
    private var lastTitle = ""
    private var interval: TimeInterval = 1.0
    private var menuBarContent: MenuBarContent = .cpuTemp
    private lazy var processDetails = ProcessDetailsWindowController()
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var statusItemHidden = false
    private var suppressReopenUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If an instance is already running (e.g. `open -n`), ask it to show the
        // panel and exit instead of adding a second, invisible menu bar item.
        if let identifier = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    showPanelNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                NSApp.terminate(nil)
                return
            }
        }

        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        interval = savedInterval >= 0.2 ? savedInterval : 1.0
        menuBarContent = MenuBarContent(
            rawValue: UserDefaults.standard.string(forKey: "menuBarContent") ?? ""
        ) ?? .cpuMemory

        if UserDefaults.standard.bool(forKey: "showDockIcon") {
            NSApp.setActivationPolicy(.regular)
        }

        setupStatusItem()
        setupPopover()
        setupEngine()
        observeSleepWake()
        registerHotKey()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPanelFromNotification),
            name: showPanelNotification,
            object: nil
        )

        // First ever launch: show the panel once so double-clicking the app
        // always produces visible feedback, even if the menu bar is full.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkStatusItemVisibility()
        }

        if ProcessInfo.processInfo.environment["SNM_SHOW_PROCESSES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showProcessDetails()
            }
        }

        if let path = ProcessInfo.processInfo.environment["SNM_SNAPSHOT_PROCESSES"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.showProcessDetails()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.processDetails.snapshot(to: path)
                }
            }
        }

        if ProcessInfo.processInfo.environment["SNM_STATS"] == "1" {
            startStatsLogging()
        }

        if let path = ProcessInfo.processInfo.environment["SNM_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                if let snapshot = self.latest {
                    self.panel.update(snapshot, history: self.history, interval: self.interval)
                }
                self.writePanelSnapshot(to: path)
            }
        }

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    /// Double-clicking the app (or clicking its Dock icon) reopens the panel.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if let suppressReopenUntil, Date() < suppressReopenUntil {
            return false
        }
        showPopover()
        return false
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "sn-monitor（⌃⌥M 打开面板）"
        lastTitle = placeholderTitle
        button.attributedTitle = attributedTitle(placeholderTitle)
    }

    private func setupPopover() {
        panel = PanelViewController()
        panel.onSettings = { [weak self] anchor in
            self?.showSettingsMenu(relativeTo: anchor)
        }
        panel.onQuit = {
            NSApp.terminate(nil)
        }
        panel.onShowProcesses = { [weak self] in
            self?.showProcessDetails()
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 404)
        popover.contentViewController = panel
        popover.delegate = self
    }

    private func setupEngine() {
        engine = MetricsEngine(interval: interval)
        engine.onSnapshot = { [weak self] snapshot in
            self?.handle(snapshot)
        }
        engine.start()
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        for name in sleepNames {
            center.addObserver(self, selector: #selector(systemWillSleep), name: name, object: nil)
        }
        for name in wakeNames {
            center.addObserver(self, selector: #selector(systemDidWake), name: name, object: nil)
        }
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D53_4B54), id: 1) // 'MSKT'
        let options = UInt32(controlKey | optionKey)
        guard RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            options,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        ) == noErr else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
    }

    private func writePanelSnapshot(to path: String) {
        let view = panel.view
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
        print("panel snapshot: \(path)")
        fflush(stdout)
    }

    private func startStatsLogging() {
        var lastCPUTime: Double = 0
        var lastWall = Date()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            _ = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpuTime = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            let now = Date()
            let percent = (cpuTime - lastCPUTime) / now.timeIntervalSince(lastWall) * 100
            lastCPUTime = cpuTime
            lastWall = now
            print(String(
                format: "stats footprint=%.1f MB cpu=%.2f%% shown=%@",
                Double(info.phys_footprint) / 1_048_576,
                percent,
                self.popover.isShown ? "yes" : "no"
            ))
            fflush(stdout)
        }
    }

    // MARK: - Sampling

    private func handle(_ snapshot: Snapshot) {
        latest = snapshot
        history.append(snapshot)

        refreshStatusItem()

        if popover.isShown {
            panel.update(snapshot, history: history, interval: interval)
        }
    }

    private func refreshStatusItem() {
        // A hidden menu bar item costs a redraw per tick and shows nothing.
        guard !statusItemHidden, let button = statusItem.button else { return }

        if menuBarContent == .iconOnly {
            if button.image == nil {
                let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "sn-monitor")
                image?.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
                button.attributedTitle = NSAttributedString(string: "")
            }
            lastTitle = ""
            return
        }

        button.image = nil
        let title: String
        if let snapshot = latest {
            var parts: [String] = [String(format: "%2.0f%%", snapshot.cpu.usage * 100)]
            switch menuBarContent {
            case .cpuMemoryTemp:
                parts.append(String(format: "%2.0f%%", snapshot.memory.usage * 100))
                parts.append(temperatureString(snapshot))
            case .cpuMemory:
                parts.append(String(format: "%2.0f%%", snapshot.memory.usage * 100))
            case .cpuTemp:
                parts.append(temperatureString(snapshot))
            case .cpuOnly, .iconOnly:
                break
            }
            title = parts.joined(separator: " ")
        } else {
            title = placeholderTitle
        }

        if title != lastTitle {
            lastTitle = title
            button.attributedTitle = attributedTitle(title)
            if ProcessInfo.processInfo.environment["SNM_STATS"] == "1" {
                print("menuBarTitle=\(title)")
                fflush(stdout)
            }
        }
    }

    private func temperatureString(_ snapshot: Snapshot) -> String {
        snapshot.thermal.cpuCelsius.map { String(format: "%2.0f°", $0) } ?? "--°"
    }

    private var placeholderTitle: String {
        switch menuBarContent {
        case .cpuMemoryTemp: return "--% --% --°"
        case .cpuMemory: return "--% --%"
        case .cpuTemp: return "--% --°"
        case .cpuOnly: return "--%"
        case .iconOnly: return ""
        }
    }

    private func attributedTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    /// macOS hides menu bar extras that do not fit, usually under the notch.
    /// When that happens there is no visible way to open the app, so fall back
    /// to a Dock icon (reversible from the settings menu) and surface a hint in
    /// the panel.
    private func checkStatusItemVisibility() {
        guard let button = statusItem.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return
        }

        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let notchMinX = left.maxX
        let notchMaxX = right.minX
        let hidden = frame.maxX > notchMinX && frame.minX < notchMaxX

        if hidden != statusItemHidden {
            statusItemHidden = hidden
            if !hidden {
                lastTitle = ""
                refreshStatusItem()
            }
        }
        panel.setMenuBarHint(hidden)
        guard hidden else { return }

        if !UserDefaults.standard.bool(forKey: "showDockIcon"),
           !UserDefaults.standard.bool(forKey: "didAutoDockFallback") {
            UserDefaults.standard.set(true, forKey: "didAutoDockFallback")
            UserDefaults.standard.set(true, forKey: "showDockIcon")
            suppressReopenUntil = Date().addingTimeInterval(3)
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - UI actions

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showSettingsMenu()
        } else {
            togglePopover()
        }
    }

    @objc private func showPanelFromNotification() {
        showPopover()
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        if let snapshot = latest {
            panel.update(snapshot, history: history, interval: interval)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showProcessDetails() {
        if popover.isShown {
            popover.performClose(nil)
        }
        processDetails.show()
    }

    private func showSettingsMenu(relativeTo anchor: NSView? = nil) {
        let menu = makeSettingsMenu()
        if let anchor {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: anchor.bounds.maxY + 6),
                in: anchor
            )
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        }
        guard let button = statusItem.button else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 6),
            in: button
        )
    }

    private func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu()

        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for value in [0.5, 1.0, 2.0, 5.0] {
            let item = NSMenuItem(
                title: PanelViewController.intervalText(value),
                action: #selector(changeInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            item.state = abs(value - interval) < 0.01 ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let contentItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let contentMenu = NSMenu()
        for content in [MenuBarContent.cpuMemoryTemp, .cpuMemory, .cpuTemp, .cpuOnly, .iconOnly] {
            let item = NSMenuItem(
                title: content.label,
                action: #selector(changeMenuBarContent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = content.rawValue
            item.state = content == menuBarContent ? .on : .off
            contentMenu.addItem(item)
        }
        contentItem.submenu = contentMenu
        menu.addItem(contentItem)

        menu.addItem(.separator())

        let dockItem = NSMenuItem(
            title: "在 Dock 中显示",
            action: #selector(toggleDockIcon),
            keyEquivalent: ""
        )
        dockItem.target = self
        dockItem.state = UserDefaults.standard.bool(forKey: "showDockIcon") ? .on : .off
        menu.addItem(dockItem)

        let loginItem = NSMenuItem(
            title: "开机启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 sn-monitor",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "退出 sn-monitor",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        interval = value
        UserDefaults.standard.set(value, forKey: "refreshInterval")
        engine.setInterval(value)
        if let snapshot = latest {
            panel.update(snapshot, history: history, interval: interval)
        }
    }

    @objc private func changeMenuBarContent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let content = MenuBarContent(rawValue: raw) else {
            return
        }
        menuBarContent = content
        UserDefaults.standard.set(raw, forKey: "menuBarContent")
        if let button = statusItem.button {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "")
        }
        lastTitle = ""
        refreshStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.checkStatusItemVisibility()
        }
    }

    @objc private func toggleDockIcon() {
        let show = !UserDefaults.standard.bool(forKey: "showDockIcon")
        UserDefaults.standard.set(show, forKey: "showDockIcon")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法设置开机启动"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "sn-monitor v0.1.4"
        alert.informativeText = """
        轻量 macOS 系统监视器：CPU、内存、磁盘、刷新率与温度。

        温度来自 AppleSMC（私有 API，仅本机自用，不可上架 App Store）。
        默认每秒采样一次，可在菜单中调整。
        菜单栏图标被刘海遮住时，按 ⌃⌥M 打开面板。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Sleep / wake

    @objc private func systemWillSleep() {
        engine.stop()
    }

    @objc private func systemDidWake() {
        engine.resync()
        engine.start()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        checkStatusItemVisibility()
        if let snapshot = latest {
            panel.update(snapshot, history: history, interval: interval)
        }
    }
}
