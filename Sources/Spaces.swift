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

enum Palette {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemTeal,
                                    .systemBlue, .systemIndigo, .systemPurple, .systemPink]
    /// What the auto-namer's model calls each colour.
    static let colorNames = ["red", "orange", "green", "teal", "blue", "indigo", "purple", "pink"]
    /// Mascots in each colour; a named space gets one picked by its name unless the auto-namer chose one.
    static let emoji: [[String]] = [
        ["🍎", "🍓", "🌶️", "🐞", "🚒", "🌹"], ["🦊", "🍊", "🏀", "🔥", "🥕", "🐯"],
        ["🐸", "🌵", "🍀", "🥑", "🐢", "🌲"], ["🐬", "🧊", "💎", "🌊", "🦕", "🧪"],
        ["🐳", "🫐", "🧢", "🌀", "🦋", "🚙"], ["🌌", "🔮", "🪐", "☔️", "🌃", "🧿"],
        ["🍇", "👾", "🦄", "🍆", "😈", "☂️"], ["🌸", "🦩", "🐷", "🍭", "🧠", "🎀"],
    ]

    /// The menu bar item: the space's name on a solid pill in its colour, so it stands out
    /// from the monochrome icons around it.
    static func pill(_ text: String, color: Int?) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let textSize = label.size()
        let size = NSSize(width: ceil(textSize.width) + 16, height: 19)
        let image = NSImage(size: size, flipped: false) { rect in
            (color.map { colors[$0] } ?? NSColor(white: 0.45, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            label.draw(at: NSPoint(x: 8, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    static func hash(_ text: String) -> Int {
        Int(text.unicodeScalars.reduce(UInt(5381)) { ($0 &* 33) &+ UInt($1.value) } % 1_000_003)
    }
}

struct Space: Identifiable, Equatable {
    let id: UInt64            // ManagedSpaceID (not stable across reboots)
    let key: String           // stable key the name is stored under
    let appKey: String?       // full-screen spaces get a new uuid every time, so they are also keyed by app
    let displayID: String
    let index: Int            // 1-based position across all spaces
    let isFullscreen: Bool
    let desktopNumber: Int?   // "Desktop N" as Mission Control numbers it
    let isCurrent: Bool       // current space of its display
    let customName: String?
    let color: Int?           // index into Palette.colors; nil for unnamed spaces
    let emoji: String?        // mascot shown before a custom name that doesn't bring its own
    let defaultName: String
    let appPIDs: [pid_t]      // apps with windows on this space, front to back

    var name: String { customName.map { name in emoji.map { "\($0) \(name)" } ?? name } ?? defaultName }
}

final class SpaceStore: ObservableObject {
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var activeID: UInt64 = 0
    /// Window titles per space; empty unless the app has Screen Recording access.
    private(set) var windowTitles: [UInt64: [String]] = [:]

    private let cid = CGSMainConnectionID()
    private let defaults = UserDefaults.standard
    private let namesKey = "spaceNames"
    private let colorsKey = "spaceColors"
    private let emojisKey = "spaceEmojis"

    var active: Space? { spaces.first { $0.id == activeID } }

    private var names: [String: String] {
        get { defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: namesKey) }
    }

    private var colors: [String: Int] {
        get { defaults.dictionary(forKey: colorsKey) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: colorsKey) }
    }

    /// Mascots the auto-namer chose; a space without one gets a mascot picked by its name.
    private var emojis: [String: String] {
        get { defaults.dictionary(forKey: emojisKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: emojisKey) }
    }

    /// `color` and `emoji` are the auto-namer's choices; a name typed by hand passes neither.
    func setName(_ name: String, for space: Space, color: Int? = nil, emoji: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty || trimmed == space.defaultName ? nil : trimmed
        var all = names
        all[space.key] = value
        if let appKey = space.appKey { all[appKey] = value }
        names = all

        var emojis = self.emojis
        let mascot = value == nil ? nil : emoji
        emojis[space.key] = mascot
        if let appKey = space.appKey { emojis[appKey] = mascot }
        self.emojis = emojis

        // A newly named space takes a colour no other space is using; C in the switcher changes it.
        var colors = self.colors
        if value == nil {
            colors[space.key] = nil
            if let appKey = space.appKey { colors[appKey] = nil }
        } else if let color, Palette.colors.indices.contains(color) {
            colors[space.key] = color
            if let appKey = space.appKey { colors[appKey] = color }
        } else if space.customName == nil {
            let used = Set(spaces.compactMap(\.color))
            if let free = Palette.colors.indices.first(where: { !used.contains($0) }) {
                colors[space.key] = free
                if let appKey = space.appKey { colors[appKey] = free }
            }
        }
        self.colors = colors
        refresh()
    }

    /// Steps the space to the next palette colour.
    func cycleColor(for space: Space) {
        let next = ((space.color ?? -1) + 1) % Palette.colors.count
        var all = colors
        all[space.key] = next
        if let appKey = space.appKey { all[appKey] = next }
        colors = all
        refresh()
    }

    func refresh() {
        let names = self.names
        let colors = self.colors
        let emojis = self.emojis
        let apps = appsBySpace()
        var result: [Space] = []
        var desktopCount = 0
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        // A full-screen space with no name of its own inherits the last name given to its app,
        // unless another space is already using that name (two full-screen windows of one app).
        var claimed = Set(displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
            .compactMap { ($0["uuid"] as? String).flatMap { names[$0] } })
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "Main"
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            for dict in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (dict["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                let uuid = dict["uuid"] as? String ?? ""
                let fullscreen = (dict["type"] as? NSNumber)?.intValue == 4
                let pids = apps[id] ?? []
                var number: Int?
                var appKey: String?
                var defaultName: String
                if fullscreen {
                    let pid = (dict["pid"] as? NSNumber)?.int32Value ?? pids.first
                    let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                    defaultName = app?.localizedName ?? "Full Screen"
                    appKey = app?.bundleIdentifier.map { "app-\($0)" }
                } else {
                    desktopCount += 1
                    number = desktopCount
                    defaultName = "Desktop \(desktopCount)"
                }
                // The first desktop of a display has an empty uuid.
                let key = uuid.isEmpty ? "first-\(displayID)" : uuid
                var customName = names[key]
                var inherited = false
                if customName == nil, let appKey, let last = names[appKey], !claimed.contains(last) {
                    customName = last
                    inherited = true
                    claimed.insert(last)
                }
                let color = (colors[key] ?? (inherited ? appKey.flatMap { colors[$0] } : nil) ?? customName.map(Palette.hash))
                    .map { $0 % Palette.colors.count }
                var emoji: String?
                if let customName, let color, let first = customName.first, !first.startsWithEmoji {
                    // The auto-namer's mascot holds while the space keeps the colour it came with.
                    let chosen = emojis[key] ?? (inherited ? appKey.flatMap { emojis[$0] } : nil)
                    emoji = chosen.flatMap { Palette.emoji[color].contains($0) ? $0 : nil }
                        ?? Palette.emoji[color][Palette.hash(customName) % Palette.emoji[color].count]
                }
                result.append(Space(id: id, key: key, appKey: appKey, displayID: displayID, index: result.count + 1,
                                    isFullscreen: fullscreen, desktopNumber: number, isCurrent: id == current,
                                    customName: customName, color: color, emoji: emoji,
                                    defaultName: defaultName, appPIDs: pids))
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
        var titles: [UInt64: [String]] = [:]
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
            for space in spaces.map(\.uint64Value) {
                if !(result[space] ?? []).contains(pid) { result[space, default: []].append(pid) }
                if let title = info[kCGWindowName as String] as? String, !title.isEmpty, (titles[space]?.count ?? 0) < 5 {
                    titles[space, default: []].append(String(title.prefix(60)))
                }
            }
        }
        windowTitles = titles
        return result
    }
}

private extension Character {
    var startsWithEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && unicodeScalars.count > 1)
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
