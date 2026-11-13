import Cocoa
import SwiftUI

struct Chip: Identifiable, Equatable {
    let id: UInt64
    let number: Int
    let name: String
    let isCurrent: Bool
    let color: Int?
    // Only used when pinned over a space's own label:
    var center: CGPoint = .zero
    var minWidth: CGFloat?
    var maxWidth: CGFloat?
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
            if chip.maxWidth == nil { Text("\(chip.number)").opacity(0.6) }
            Text(chip.name).lineLimit(1)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(minWidth: chip.minWidth, maxWidth: chip.maxWidth)
        .background(Capsule().fill(chip.color.map { Color(nsColor: Palette.colors[$0]) } ?? Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(chip.isCurrent ? 0.95 : 0.18), lineWidth: chip.isCurrent ? 2 : 0.5))
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
    private var ticks = 0
    private var missing = 0           // updates since the Spaces bar's windows were last found
    private var windows: [String: (window: NSWindow, model: OverlayModel)] = [:]
    private var spaceLists: [AXUIElement] = []

    init(store: SpaceStore) { self.store = store }

    func start() { schedule(0.1) }

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
                missing = 0
                spaceLists = []
                schedule(0.05)
            } else {
                windows.values.forEach { $0.window.orderOut(nil) }
                schedule(0.1)
            }
        }
        if active {
            // Spaces can be added, removed and reordered without leaving Mission Control.
            ticks += 1
            if ticks % 10 == 0 { store.refresh() }
            update()
        }
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

    /// Since macOS 27 Mission Control belongs to WindowManager, which gives every space in the
    /// Spaces bar a window of its own: a thumbnail with the label beneath. Returns those windows
    /// left to right in global top-left coordinates, or nil unless there is one per space.
    private static func spaceBarWindows(in area: CGRect, count: Int) -> [CGRect]? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var rows: [String: [CGRect]] = [:]
        for info in list {
            guard info[kCGWindowOwnerName as String] as? String == "WindowManager",
                  let layer = info[kCGWindowLayer as String] as? Int, (10...18).contains(layer),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  area.contains(CGPoint(x: rect.midX, y: rect.midY)), rect.midY < area.minY + area.height * 0.3,
                  rect.width < area.width / 2, (10...40).contains(rect.height - rect.width * area.height / area.width)
            else { continue }
            rows["\(layer) \(rect.minY) \(rect.size)", default: []].append(rect)
        }
        return rows.values.filter { $0.count == count }.min { $0[0].minY < $1[0].minY }?.sorted { $0.minX < $1.minX }
    }

    /// The part of a Spaces bar item below its thumbnail, where the space's name is written.
    private static func labelStrip(of item: CGRect, on screen: NSScreen) -> CGRect {
        let thumbnail = item.width * screen.frame.height / screen.frame.width
        return CGRect(x: item.minX, y: item.minY + thumbnail, width: item.width, height: item.height - thumbnail)
    }

    private func update() {
        let frames = AXIsProcessTrusted() ? spaceButtonFrames() : []
        let mouse = NSEvent.mouseLocation
        for (displayID, spaces) in Dictionary(grouping: store.spaces, by: \.displayID) {
            guard let screen = NSScreen.forDisplay(displayID) else { continue }
            let entry = overlay(for: displayID, on: screen)
            let origin = screen.topLeftFrame.origin
            let items = Self.spaceBarWindows(in: screen.topLeftFrame, count: spaces.count)
            let onScreen = frames.first { list in
                list.count == spaces.count && list.first.map { screen.topLeftFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) } == true
            }
            var chips = spaces.map { Chip(id: $0.id, number: $0.index, name: $0.name, isCurrent: $0.isCurrent, color: $0.color) }
            missing = items == nil ? missing + 1 : 0
            if let items {
                // Exact, and needs no permission: each item is a thumbnail shaped like the screen
                // with the space's label in the strip beneath. The chip fills that strip at least
                // as wide as the label it replaces, so "Desktop 1" doesn't show around it.
                let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                for i in chips.indices {
                    let frame = items[i].offsetBy(dx: -origin.x, dy: -origin.y)
                    let label = Self.labelStrip(of: frame, on: screen)
                    let covered = (spaces[i].defaultName as NSString).size(withAttributes: [.font: font]).width + 18
                    chips[i].center = CGPoint(x: label.midX, y: label.midY)
                    chips[i].minWidth = min(frame.width, covered)
                    chips[i].maxWidth = frame.width
                }
                chips = chips.enumerated().filter { spaces[$0.offset].customName != nil }.map(\.element)
                entry.model.pinned = true
            } else if let onScreen {
                // Exact: named spaces get a chip on their own entry in the Spaces bar. While the
                // bar is a row of text labels the chip covers the label, so it reads as renamed;
                // once it grows into thumbnails the chip sits on the thumbnail's bottom edge.
                for i in chips.indices {
                    let frame = onScreen[i].offsetBy(dx: -origin.x, dy: -origin.y)
                    let isLabel = frame.height < 44
                    chips[i].center = CGPoint(x: frame.midX, y: isLabel ? frame.midY : frame.maxY)
                    chips[i].minWidth = isLabel ? frame.width + 8 : nil
                    chips[i].maxWidth = isLabel ? frame.width + 30 : max(frame.width, 60)
                }
                chips = chips.enumerated().filter { spaces[$0.offset].customName != nil }.map(\.element)
                entry.model.pinned = true
            } else {
                // No Accessibility access: a strip in space order just below the Spaces
                // bar, which grows into thumbnails once the pointer reaches the top.
                let menuBar = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
                if screen.frame.contains(mouse), screen.frame.maxY - mouse.y < menuBar + 44 { barExpanded = true }
                if #available(macOS 27, *) {
                    // The bar is always thumbnails there, and its windows can trail Mission Control
                    // by a moment; only settle for the strip once they have clearly not turned up.
                    barExpanded = true
                    if missing < 20 { chips = [] }
                }
                entry.model.pinned = false
                entry.model.stripY = barExpanded ? menuBar + screen.frame.height * 0.11 + 62 : menuBar + 58
            }
            if entry.model.chips != chips { entry.model.chips = chips }
            if !entry.window.isVisible {
                entry.window.alphaValue = 0
                entry.window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
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

    /// `SpaceTags --debug <dir>`: writes what the overlay believes it is showing, plus a picture of it.
    func debugDump(to directory: URL) {
        var lines = ["missionControl=\(active) axTrusted=\(AXIsProcessTrusted()) barExpanded=\(barExpanded)"]
        for space in store.spaces {
            lines.append("space \(space.index) id=\(space.id) key=\(space.key) name=\(space.name) custom=\(space.customName ?? "-") "
                + "color=\(space.color.map(String.init) ?? "-") current=\(space.isCurrent) fullscreen=\(space.isFullscreen) apps=\(space.appPIDs.count)")
        }
        if AXIsProcessTrusted() {
            lines.append("axFrames=\(spaceButtonFrames())")
            if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                let app = AXUIElementCreateApplication(dock.processIdentifier)
                for child in children(of: app) where string(kAXIdentifierAttribute, of: child)?.hasPrefix("mc") == true {
                    dumpTree(child, depth: 0, into: &lines)
                }
            }
        }
        for (displayID, spaces) in Dictionary(grouping: store.spaces, by: \.displayID) {
            guard let screen = NSScreen.forDisplay(displayID) else { continue }
            let items = Self.spaceBarWindows(in: screen.topLeftFrame, count: spaces.count)
            lines.append("barWindows \(displayID) spaces=\(spaces.count) items=\(items.map { "\($0)" } ?? "-")")
            for item in items ?? [] { lines.append("  labelStrip=\(Self.labelStrip(of: item, on: screen))") }
        }
        for (id, entry) in windows {
            let window = entry.window
            lines.append("window \(id) frame=\(window.frame) visible=\(window.isVisible) alpha=\(window.alphaValue) "
                + "occlusionVisible=\(window.occlusionState.contains(.visible)) pinned=\(entry.model.pinned) stripY=\(entry.model.stripY)")
            for chip in entry.model.chips {
                lines.append("  chip \(chip.number) \(chip.name) center=\(chip.center) minWidth=\(chip.minWidth ?? 0) maxWidth=\(chip.maxWidth ?? 0)")
            }
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("overlay-\(id).png"))
            }
        }
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("debug.txt"), atomically: true, encoding: .utf8)
    }

    private func dumpTree(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 8 else { return }
        let fields = [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .map { string($0, of: element) ?? "-" }.joined(separator: " | ")
        lines.append(String(repeating: "  ", count: depth) + "ax " + fields + " " + (frame(of: element).map { "\($0)" } ?? "-"))
        for child in children(of: element) { dumpTree(child, depth: depth + 1, into: &lines) }
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
