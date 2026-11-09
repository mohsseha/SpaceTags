import Cocoa
import SwiftUI

struct Chip: Identifiable, Equatable {
    let id: UInt64
    let number: Int
    let name: String
    let isCurrent: Bool
    var center: CGPoint = .zero   // only used when pinned
}

final class OverlayModel: ObservableObject {
    @Published var chips: [Chip] = []
    @Published var pinned = false     // true: each chip sits under its space; false: one centered strip
    @Published var stripY: CGFloat = 0
}

private struct ChipView: View {
    let chip: Chip
    var body: some View {
        HStack(spacing: 5) {
            Text("\(chip.number)").opacity(0.6)
            Text(chip.name).lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(chip.isCurrent ? Color.accentColor : Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .fixedSize()
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        GeometryReader { geo in
            if model.pinned {
                ForEach(model.chips) { chip in
                    ChipView(chip: chip).position(chip.center)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(model.chips) { ChipView(chip: $0) }
                }
                .fixedSize()
                .position(x: geo.size.width / 2, y: model.stripY)
            }
        }
    }
}

/// Draws space names on top of Mission Control. The Dock owns Mission Control
/// and can't be modified, so we float our own click-through windows above it.
final class MissionControlOverlay {
    private let store: SpaceStore
    private var timer: Timer?
    private var active = false
    private var barExpanded = false
    private var windows: [String: (window: NSWindow, model: OverlayModel)] = [:]
    private var spaceLists: [AXUIElement] = []

    init(store: SpaceStore) { self.store = store }

    func start() { schedule(0.15) }

    func screensChanged() {
        windows.values.forEach { $0.window.orderOut(nil) }
        windows.removeAll()
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let visible = Self.missionControlVisible()
        if visible != active {
            active = visible
            if visible {
                store.refresh()
                barExpanded = false
                spaceLists = []
                schedule(0.05)
            } else {
                windows.values.forEach { $0.window.orderOut(nil) }
                schedule(0.15)
            }
        }
        if active { update() }
    }

    /// Mission Control shows up as full-screen Dock windows at layers 18–20.
    private static func missionControlVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard info[kCGWindowOwnerName as String] as? String == "Dock",
                  let layer = info[kCGWindowLayer as String] as? Int, (18...20).contains(layer),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) >= 800, (bounds["Height"] as? Double ?? 0) >= 500
            else { continue }
            return true
        }
        return false
    }

    private func update() {
        let frames = AXIsProcessTrusted() ? spaceButtonFrames() : []
        let mouse = NSEvent.mouseLocation
        for (displayID, spaces) in Dictionary(grouping: store.spaces, by: \.displayID) {
            guard let screen = NSScreen.forDisplay(displayID) else { continue }
            let entry = overlay(for: displayID, on: screen)
            let origin = screen.topLeftFrame.origin
            let onScreen = frames.first { list in
                list.count == spaces.count && list.first.map { screen.topLeftFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) } == true
            }
            var chips = spaces.map { Chip(id: $0.id, number: $0.index, name: $0.name, isCurrent: $0.isCurrent) }
            if let onScreen {
                // Exact: one chip right below each space in the Spaces bar. Unnamed
                // spaces already read "Desktop N" there, so only named ones get a chip.
                for i in chips.indices {
                    chips[i].center = CGPoint(x: onScreen[i].midX - origin.x, y: onScreen[i].maxY - origin.y + 13)
                }
                chips = chips.enumerated().filter { spaces[$0.offset].customName != nil }.map(\.element)
                entry.model.pinned = true
            } else {
                // No Accessibility access: a strip in space order just below the Spaces
                // bar, which grows into thumbnails once the pointer reaches the top.
                let menuBar = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
                if screen.frame.contains(mouse), screen.frame.maxY - mouse.y < menuBar + 44 { barExpanded = true }
                entry.model.pinned = false
                entry.model.stripY = barExpanded ? menuBar + screen.frame.height * 0.11 + 62 : menuBar + 58
            }
            if entry.model.chips != chips { entry.model.chips = chips }
            if !entry.window.isVisible {
                entry.window.alphaValue = 0
                entry.window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    entry.window.animator().alphaValue = 1
                }
            }
        }
    }

    private func overlay(for displayID: String, on screen: NSScreen) -> (window: NSWindow, model: OverlayModel) {
        if let entry = windows[displayID] {
            if entry.window.frame != screen.frame { entry.window.setFrame(screen.frame, display: true) }
            return entry
        }
        let model = OverlayModel()
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: OverlayView(model: model))
        windows[displayID] = (window, model)
        return (window, model)
    }

    // MARK: Accessibility — where the Dock drew each space in the Spaces bar

    private func spaceButtonFrames() -> [[CGRect]] {
        if spaceLists.isEmpty {
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.25)
            spaceLists = find("mc.spaces.list", in: app, depth: 5)
        }
        let frames = spaceLists.map { children(of: $0).compactMap(frame(of:)) }.filter { !$0.isEmpty }
        if frames.isEmpty { spaceLists = [] }
        return frames
    }

    private func find(_ identifier: String, in element: AXUIElement, depth: Int) -> [AXUIElement] {
        if string(kAXIdentifierAttribute, of: element) == identifier { return [element] }
        guard depth > 0 else { return [] }
        // Below the app element, everything Mission Control is identified "mc…".
        return children(of: element)
            .filter { string(kAXIdentifierAttribute, of: $0)?.hasPrefix("mc") == true }
            .flatMap { find(identifier, in: $0, depth: depth - 1) }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}
