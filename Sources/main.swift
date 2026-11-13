import Cocoa
import Carbon.HIToolbox
import Combine
import ServiceManagement

let commandNotification = Notification.Name("local.spacetags.command")

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    static func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                HotKeys.handlers[id.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x5350_5447, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr { handlers[id] = handler } else { NSLog("SpaceTags: hotkey \(keyCode) unavailable (\(status))") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SpaceStore()
    private lazy var switcher = Switcher(store: store)
    private lazy var panel = PanelController(store: store) { [weak self] in self?.switcher.go(to: $0) }
    private lazy var overlay = MissionControlOverlay(store: store)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.refresh()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.$spaces.combineLatest(store.$activeID)
            .sink { [weak self] spaces, activeID in
                let space = spaces.first { $0.id == activeID }
                let name = space?.name ?? "Spaces"
                // Small screens (and notched ones) have little menu bar room, so the pill gets shorter there.
                let limit = (NSScreen.main?.frame.width ?? 0) < 1600 ? 12 : 20
                self?.statusItem.button?.image = Palette.pill(name.count > limit ? name.prefix(limit - 1) + "…" : name, color: space?.color)
                self?.statusItem.button?.imagePosition = .imageOnly
            }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.panel.hide()
            self?.store.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.overlay.screensChanged()
            self?.store.refresh()
        }
        DistributedNotificationCenter.default().addObserver(forName: commandNotification, object: nil, queue: .main) { [weak self] note in
            self?.run(command: note.object as? String ?? "")
        }

        // ⌘0 opens the switcher; ⌃⌥1…9 jump straight to a space.
        HotKeys.register(keyCode: kVK_ANSI_0, modifiers: cmdKey) { [weak self] in self?.panel.toggle() }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, keyCode) in digits.enumerated() {
            HotKeys.register(keyCode: keyCode, modifiers: controlKey | optionKey) { [weak self] in self?.go(toIndex: i + 1) }
        }

        overlay.start()

        if !UserDefaults.standard.bool(forKey: "autoNamedOnce") {
            UserDefaults.standard.set(true, forKey: "autoNamedOnce")
            autoName()
        }

        // Come back after a reboot, once the app lives somewhere permanent.
        if Bundle.main.bundlePath.contains("/Applications/"), !UserDefaults.standard.bool(forKey: "registeredLoginItem") {
            UserDefaults.standard.set(true, forKey: "registeredLoginItem")
            try? SMAppService.mainApp.register()
        }

        // Accessibility is optional: before macOS 27 it lets Mission Control labels sit exactly
        // under each space. Since then the overlay finds the spaces without it.
        if #available(macOS 27, *) {} else if !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            requestAccessibility()
        }
    }

    private func go(toIndex index: Int) {
        store.refresh()
        guard store.spaces.indices.contains(index - 1) else { return }
        panel.hide()
        switcher.go(to: store.spaces[index - 1])
    }

    /// Names every unnamed desktop after what is open on it. Full-screen spaces already show their app.
    @objc private func autoName() {
        store.refresh()
        let titles = store.windowTitles
        let targets = store.spaces.filter { !$0.isFullscreen && $0.customName == nil && !$0.appPIDs.isEmpty }
        Task { @MainActor in
            for space in targets {
                let apps = space.appPIDs.prefix(6).compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
                let usedColors = Set(store.spaces.compactMap(\.color))
                guard let suggestion = await AutoNamer.suggest(apps: apps, titles: titles[space.id] ?? [], taken: usedColors),
                      let current = store.spaces.first(where: { $0.key == space.key }), current.customName == nil
                else { continue }
                // Two desktops with similar apps would otherwise get the same name.
                let name = suggestion.name
                let taken = Set(store.spaces.compactMap(\.customName))
                let unique = [name] + (2...9).map { "\(name) \($0)" }
                store.setName(unique.first { !taken.contains($0) } ?? name, for: current,
                              color: suggestion.color, emoji: suggestion.emoji)
            }
        }
    }

    private func run(command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "toggle": panel.toggle()
        case "goto": if let index = parts.last.flatMap(Int.init) { go(toIndex: index) }
        case "autoname": autoName()
        case "debug": overlay.debugDump(to: URL(fileURLWithPath: parts.count > 1 ? parts[1] : NSTemporaryDirectory()))
        case "color":
            store.refresh()
            if let index = parts.last.flatMap(Int.init), store.spaces.indices.contains(index - 1) {
                store.cycleColor(for: store.spaces[index - 1])
            }
        case "name":
            store.refresh()
            let fields = (parts.last ?? "").split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if fields.count == 2, let index = Int(fields[0]), store.spaces.indices.contains(index - 1) {
                store.setName(fields[1], for: store.spaces[index - 1])
            }
        default: break
        }
    }

    private static func title(_ text: String, color: Int?) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        if let color {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: Palette.colors[color], .font: font]))
        }
        title.append(NSAttributedString(string: text, attributes: [.font: font]))
        return title
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.refresh()
        menu.removeAllItems()
        for space in store.spaces {
            let item = NSMenuItem(title: "", action: #selector(pickSpace(_:)), keyEquivalent: "")
            item.attributedTitle = Self.title("\(space.index)   \(space.name)", color: space.emoji == nil ? space.color : nil)
            item.target = self
            item.tag = space.index
            item.state = space.id == store.activeID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Switcher", action: #selector(showSwitcher), keyEquivalent: "0")
        show.target = self
        menu.addItem(show)
        let rename = NSMenuItem(title: "Rename This Space…", action: #selector(renameCurrent), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let auto = NSMenuItem(title: "Auto-Name Unnamed Spaces", action: #selector(autoName), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        menu.addItem(.separator())
        if #available(macOS 27, *) {} else if !AXIsProcessTrusted() {
            let access = NSMenuItem(title: "Pin Labels Under Spaces (Grant Accessibility)…", action: #selector(grantAccessibility), keyEquivalent: "")
            access.target = self
            menu.addItem(access)
        }
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit SpaceTags", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func pickSpace(_ sender: NSMenuItem) { go(toIndex: sender.tag) }
    @objc private func showSwitcher() { panel.show() }
    @objc private func renameCurrent() { panel.show(renaming: true) }

    @objc private func grantAccessibility() {
        requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("SpaceTags: launch at login failed: \(error)")
        }
    }
}

// `SpaceTags --goto 2`, `--toggle`, `--name 2=Mail`, `--color 2`, `--autoname` drive the running instance.
let arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.first, ["--goto", "--toggle", "--name", "--color", "--autoname", "--debug"].contains(flag) {
    let command = String(flag.dropFirst(2)) + (arguments.count > 1 ? ":" + arguments[1] : "")
    DistributedNotificationCenter.default().postNotificationName(commandNotification, object: command, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
