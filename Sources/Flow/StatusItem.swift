import AppKit
import FlowCore

/// The menu bar item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum IconState { case idle, listening, processing, error }

    let item: NSStatusItem
    private let menu = NSMenu()
    private var animTimer: Timer?
    private var animFrame = 0
    private var errorResetTask: Task<Void, Never>?
    private(set) var iconState: IconState = .idle

    var onToggleDictation: (() -> Void)?
    var onPickBackend: ((CleanupBackend) -> Void)?
    var onOpen: ((WindowKind) -> Void)?
    var availability: (CleanupBackend) -> CleanerAvailability = { _ in CleanerAvailability(available: false) }

    private let hotkeyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "Last: —", action: nil, keyEquivalent: "")
    private let cleanupMenu = NSMenu(title: "Cleanup")

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildMenu()
        setIcon(.idle)
    }

    private func buildMenu() {
        menu.delegate = self
        hotkeyItem.isEnabled = false
        lastItem.isEnabled = false
        menu.addItem(hotkeyItem)
        menu.addItem(lastItem)
        menu.addItem(.separator())
        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        for b in CleanupBackend.allCases {
            let mi = NSMenuItem(title: b.title, action: #selector(pickBackend(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = b.rawValue
            cleanupMenu.addItem(mi)
        }
        cleanupItem.submenu = cleanupMenu
        menu.addItem(cleanupItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("History…", .history, "h"))
        menu.addItem(makeItem("Dictionary…", .dictionary, "d"))
        menu.addItem(makeItem("Settings…", .settings, ","))
        menu.addItem(makeItem("Check permissions…", .onboarding, ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.autoenablesItems = false
    }

    private func makeItem(_ title: String, _ kind: WindowKind, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(openWindow(_:)), keyEquivalent: key)
        mi.target = self
        mi.representedObject = kind.rawValue
        return mi
    }

    func update(hotkey: HotkeySpec, mode: HotkeyMode) {
        let verb = mode == .hold ? "Hold" : "Tap"
        hotkeyItem.title = "\(verb) \(hotkey.displayString) to dictate"
    }

    func update(timings: (sttMs: Int, cleanupMs: Int?)?) {
        guard let t = timings else { lastItem.title = "Last: —"; return }
        var s = String(format: "Last: %.1f s speech", Double(t.sttMs) / 1000)
        if let c = t.cleanupMs { s += String(format: ", %.1f s cleanup", Double(c) / 1000) }
        lastItem.title = s
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = Settings.shared.cleanupBackend
        for mi in cleanupMenu.items {
            guard let raw = mi.representedObject as? String, let b = CleanupBackend(rawValue: raw) else { continue }
            let a = availability(b)
            mi.isEnabled = a.available
            mi.state = b == current ? .on : .off
            mi.toolTip = a.available ? nil : a.reason
        }
    }

    // MARK: Actions

    @objc private func clicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .leftMouseUp, ev?.modifierFlags.contains(.option) == true {
            onToggleDictation?()
            return
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func pickBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let b = CleanupBackend(rawValue: raw) else { return }
        onPickBackend?(b)
    }

    @objc private func openWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = WindowKind(rawValue: raw) else { return }
        onOpen?(k)
    }

    // MARK: Icon

    func setIcon(_ state: IconState) {
        iconState = state
        animTimer?.invalidate(); animTimer = nil
        errorResetTask?.cancel()
        item.button?.alphaValue = 1
        switch state {
        case .idle:
            item.button?.image = symbol("mic")
        case .listening:
            item.button?.image = symbol("mic.fill")
            var up = false
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    up.toggle()
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.5
                        self?.item.button?.animator().alphaValue = up ? 0.35 : 1
                    }
                }
            }
        case .processing:
            animFrame = 0
            item.button?.image = Self.spinnerFrame(0)
            animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.animFrame = (self.animFrame + 1) % 12
                    self.item.button?.image = Self.spinnerFrame(self.animFrame)
                }
            }
        case .error:
            item.button?.image = Self.badged(symbol("mic"))
            errorResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.setIcon(.idle)
            }
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Flow")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        img?.isTemplate = true
        return img
    }

    private static func spinnerFrame(_ i: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            for k in 0..<12 {
                let alpha = CGFloat(((k - i) % 12 + 12) % 12) / 12
                NSColor.black.withAlphaComponent(0.15 + 0.85 * (1 - alpha)).setStroke()
                let angle = CGFloat(k) / 12 * 2 * .pi
                let p = NSBezierPath()
                p.move(to: NSPoint(x: c.x + cos(angle) * 4.5, y: c.y + sin(angle) * 4.5))
                p.line(to: NSPoint(x: c.x + cos(angle) * 8, y: c.y + sin(angle) * 8))
                p.lineWidth = 1.6
                p.lineCapStyle = .round
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func badged(_ base: NSImage?) -> NSImage? {
        guard let base else { return nil }
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

extension CleanupBackend {
    var title: String {
        switch self {
        case .apple: return "Apple"
        case .ollama: return "Ollama"
        case .rules: return "Rules"
        case .off: return "Off"
        }
    }
}

enum WindowKind: String, CaseIterable {
    case onboarding, history, dictionary, settings
}
