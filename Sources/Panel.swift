import Cocoa
import SwiftUI

final class PanelModel: ObservableObject {
    @Published var selection = 0          // index into store.spaces
    @Published var editingKey: String?
    @Published var draft = ""
    static let maxColumns = 6
}

private final class SwitcherPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

final class PanelController {
    private let store: SpaceStore
    private let model = PanelModel()
    private let panel: SwitcherPanel
    private let hosting: NSHostingView<PanelView>
    private let onPick: (Space) -> Void

    var isVisible: Bool { panel.isVisible }

    init(store: SpaceStore, onPick: @escaping (Space) -> Void) {
        self.store = store
        self.onPick = onPick
        panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: PanelView(store: store, model: model, pick: { _ in }, rename: { _ in }))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        hosting.rootView = PanelView(store: store, model: model,
                                     pick: { [weak self] in self?.pick($0) },
                                     rename: { [weak self] in self?.beginRename($0) })
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        panel.onResign = { [weak self] in self?.hide() }
    }

    func toggle() { isVisible ? hide() : show() }

    func show(renaming: Bool = false) {
        store.refresh()
        model.editingKey = nil
        model.selection = store.spaces.firstIndex { $0.id == store.activeID } ?? 0
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2 + screen.frame.height * 0.08)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        if renaming, store.spaces.indices.contains(model.selection) {
            beginRename(store.spaces[model.selection])
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        model.editingKey = nil
        panel.orderOut(nil)
    }

    private func pick(_ space: Space) {
        hide()
        onPick(space)
    }

    private func beginRename(_ space: Space) {
        model.selection = space.index - 1
        model.draft = space.customName ?? ""
        model.editingKey = space.key
    }

    private func move(_ delta: Int) {
        let count = store.spaces.count
        guard count > 0 else { return }
        model.selection = ((model.selection + delta) % count + count) % count
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if model.editingKey != nil {
            guard event.keyCode == 53 else { return false }   // typing goes to the text field
            model.editingKey = nil
            return true
        }
        let spaces = store.spaces
        let columns = min(max(spaces.count, 1), PanelModel.maxColumns)
        switch event.keyCode {
        case 53: hide()                                                       // esc
        case 36, 76: if spaces.indices.contains(model.selection) { pick(spaces[model.selection]) }
        case 123: move(-1)
        case 124: move(1)
        case 125: if model.selection + columns < spaces.count { model.selection += columns }
        case 126: if model.selection - columns >= 0 { model.selection -= columns }
        case 48: move(event.modifierFlags.contains(.shift) ? -1 : 1)          // tab
        case 120: if spaces.indices.contains(model.selection) { beginRename(spaces[model.selection]) }  // F2
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let digit = Int(chars), digit >= 1, digit <= spaces.count {
                pick(spaces[digit - 1])
            } else if chars == "r" || chars == "e", spaces.indices.contains(model.selection) {
                beginRename(spaces[model.selection])
            } else if chars == "c", spaces.indices.contains(model.selection) {
                store.cycleColor(for: spaces[model.selection])
            }
        }
        return true
    }
}

struct PanelView: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var model: PanelModel
    let pick: (Space) -> Void
    let rename: (Space) -> Void

    var body: some View {
        let columns = min(max(store.spaces.count, 1), PanelModel.maxColumns)
        VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 10), count: columns), spacing: 10) {
                ForEach(store.spaces) { space in
                    SpaceCard(space: space, model: model,
                              selected: model.selection == space.index - 1,
                              pick: { pick(space) }, rename: { rename(space) },
                              commit: { store.setName(model.draft, for: space); model.editingKey = nil })
                }
            }
            Text(model.editingKey == nil
                 ? "1–9 jump   ←→ select   ⏎ go   R rename   C color   esc close"
                 : "⏎ save   esc cancel   (empty = default name)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .fixedSize()
    }
}

private struct SpaceCard: View {
    let space: Space
    @ObservedObject var model: PanelModel
    let selected: Bool
    let pick: () -> Void
    let rename: () -> Void
    let commit: () -> Void
    @FocusState private var focused: Bool

    private var editing: Bool { model.editingKey == space.key }
    private var tint: Color { space.color.map { Color(nsColor: Palette.colors[$0]) } ?? .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(space.index <= 9 ? "\(space.index)" : "·")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.12)))
                if space.isCurrent {
                    Circle().fill(.primary).frame(width: 7, height: 7)
                }
                Spacer()
                Button(action: rename) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(selected ? 1 : 0.35)
            }
            HStack(spacing: 3) {
                ForEach(space.appPIDs.prefix(4), id: \.self) { pid in
                    if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                }
                if space.appPIDs.count > 4 {
                    Text("+\(space.appPIDs.count - 4)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 22, alignment: .leading)
            if editing {
                TextField(space.defaultName, text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onAppear { DispatchQueue.main.async { focused = true } }
            } else {
                Text(space.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Text(space.customName != nil ? space.defaultName : (space.isFullscreen ? "Full screen" : "Unnamed"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(space.color == nil ? (selected ? 0.16 : 0.06) : (selected ? 0.55 : 0.3))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.primary.opacity(0.85) : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { pick() } }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
