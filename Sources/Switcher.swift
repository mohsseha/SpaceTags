import Cocoa

private final class AnchorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Switches Spaces without any permissions: an invisible window of ours is
/// moved to the target space and activated, and macOS follows it there.
final class Switcher {
    private let cid = CGSMainConnectionID()
    private let store: SpaceStore
    private var generation = 0

    private lazy var anchor: AnchorWindow = {
        let window = AnchorWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.ignoresCycle]
        return window
    }()

    init(store: SpaceStore) { self.store = store }

    func go(to space: Space) {
        guard CGSGetActiveSpace(cid) != space.id else { return }
        generation += 1
        let generation = self.generation

        if let screen = NSScreen.forDisplay(space.displayID) {
            anchor.setFrameOrigin(NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
        anchor.orderFront(nil)
        CGSMoveWindowsToManagedSpace(cid, [NSNumber(value: anchor.windowNumber)] as CFArray, space.id)
        NSApp.activate(ignoringOtherApps: true)
        anchor.makeKeyAndOrderFront(nil)
        awaitArrival(at: space, generation: generation, deadline: Date().addingTimeInterval(1.0))
    }

    private func awaitArrival(at space: Space, generation: Int, deadline: Date) {
        guard generation == self.generation else { return }
        if CGSGetActiveSpace(cid) == space.id {
            // Let the slide animation settle before handing focus to an app there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard generation == self.generation else { return }
                self.handOff(space)
            }
        } else if Date() > deadline {
            anchor.orderOut(nil)
            pressDesktopShortcut(for: space)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.awaitArrival(at: space, generation: generation, deadline: deadline)
            }
        }
    }

    /// Focus the frontmost app on the space we just arrived at.
    private func handOff(_ space: Space) {
        let front = frontmostApp(on: space.id)
        anchor.orderOut(nil)
        front?.activate()
    }

    private func frontmostApp(on spaceID: UInt64) -> NSRunningApplication? {
        let me = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) >= 100, (bounds["Height"] as? Double ?? 0) >= 60,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { continue }
            let spaces = CGSCopySpacesForWindows(cid, 7, [NSNumber(value: number)] as CFArray) as? [NSNumber] ?? []
            if spaces.contains(where: { $0.uint64Value == spaceID }) { return app }
        }
        return nil
    }

    /// Fallback: press the system "Switch to Desktop N" shortcut (needs Accessibility).
    private func pressDesktopShortcut(for space: Space) {
        guard CGPreflightPostEventAccess(), let number = space.desktopNumber, number <= 16 else { return }
        let hotKey = Int32(118 + number - 1)
        var char: UniChar = 0, keyCode: UInt16 = 0, mods: UInt32 = 0
        guard CGSGetSymbolicHotKeyValue(hotKey, &char, &keyCode, &mods) == 0 else { return }
        let wasEnabled = CGSIsSymbolicHotKeyEnabled(hotKey)
        if !wasEnabled { _ = CGSSetSymbolicHotKeyEnabled(hotKey, true) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: UInt64(mods))
            event?.post(tap: .cghidEventTap)
        }
        if !wasEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = CGSSetSymbolicHotKeyEnabled(hotKey, false) }
        }
    }
}
