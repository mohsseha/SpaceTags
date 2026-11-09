import Cocoa

// Private WindowServer (CGS/SkyLight) calls. There is no public API for Spaces.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
@_silgen_name("CGSMoveWindowsToManagedSpace") func CGSMoveWindowsToManagedSpace(_ cid: Int32, _ windows: CFArray, _ space: UInt64)
@_silgen_name("CGSGetSymbolicHotKeyValue") func CGSGetSymbolicHotKeyValue(_ hotKey: Int32, _ char: UnsafeMutablePointer<UniChar>, _ keyCode: UnsafeMutablePointer<UInt16>, _ mods: UnsafeMutablePointer<UInt32>) -> Int32
@_silgen_name("CGSIsSymbolicHotKeyEnabled") func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool
@_silgen_name("CGSSetSymbolicHotKeyEnabled") func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

struct Space: Identifiable, Equatable {
    let id: UInt64            // ManagedSpaceID (not stable across reboots)
    let key: String           // stable key the name is stored under
    let displayID: String
    let index: Int            // 1-based position across all spaces
    let isFullscreen: Bool
    let desktopNumber: Int?   // "Desktop N" as Mission Control numbers it
    let isCurrent: Bool       // current space of its display
    let customName: String?
    let defaultName: String
    let appPIDs: [pid_t]      // apps with windows on this space, front to back

    var name: String { customName ?? defaultName }
}

final class SpaceStore: ObservableObject {
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var activeID: UInt64 = 0

    private let cid = CGSMainConnectionID()
    private let defaults = UserDefaults.standard
    private let namesKey = "spaceNames"

    var active: Space? { spaces.first { $0.id == activeID } }

    private var names: [String: String] {
        get { defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: namesKey) }
    }

    func setName(_ name: String, for space: Space) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = names
        all[space.key] = trimmed.isEmpty || trimmed == space.defaultName ? nil : trimmed
        names = all
        refresh()
    }

    func refresh() {
        let names = self.names
        let apps = appsBySpace()
        var result: [Space] = []
        var desktopCount = 0
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "Main"
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            for dict in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (dict["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let uuid = dict["uuid"] as? String ?? ""
                let fullscreen = (dict["type"] as? NSNumber)?.intValue == 4
                let pids = apps[id] ?? []
                var number: Int?
                var defaultName: String
                if fullscreen {
                    defaultName = pids.first.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Full Screen"
                } else {
                    desktopCount += 1
                    number = desktopCount
                    defaultName = "Desktop \(desktopCount)"
                }
                // The first desktop of a display has an empty uuid.
                let key = uuid.isEmpty ? "first-\(displayID)" : uuid
                result.append(Space(id: id, key: key, displayID: displayID, index: result.count + 1,
                                    isFullscreen: fullscreen, desktopNumber: number, isCurrent: id == current,
                                    customName: names[key], defaultName: defaultName, appPIDs: pids))
            }
        }
        let active = CGSGetActiveSpace(cid)
        if result != spaces { spaces = result }
        if active != activeID { activeID = active }
    }

    /// Regular apps that have a normal window on each space, front to back.
    private func appsBySpace() -> [UInt64: [pid_t]] {
        let me = getpid()
        var regular: [pid_t: Bool] = [:]
        var result: [UInt64: [pid_t]] = [:]
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) >= 100, (bounds["Height"] as? Double ?? 0) >= 60,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            if regular[pid] == nil {
                regular[pid] = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            }
            guard regular[pid] == true else { continue }
            let spaces = CGSCopySpacesForWindows(cid, 7, [NSNumber(value: number)] as CFArray) as? [NSNumber] ?? []
            for space in spaces where !(result[space.uint64Value] ?? []).contains(pid) {
                result[space.uint64Value, default: []].append(pid)
            }
        }
        return result
    }
}

extension NSScreen {
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Frame in the global top-left-origin coordinates used by CoreGraphics and Accessibility.
    var topLeftFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func forDisplay(_ displayID: String) -> NSScreen? {
        screens.first { $0.displayUUID == displayID } ?? screens.first
    }
}
