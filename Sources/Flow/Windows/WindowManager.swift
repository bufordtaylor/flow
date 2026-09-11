import AppKit
import FlowCore
import SwiftUI

struct WindowSpec {
    let kind: WindowKind
    let title: String
    let size: NSSize
    let minSize: NSSize?
    let resizable: Bool
    let autosave: String?

    static let all: [WindowSpec] = [
        WindowSpec(kind: .onboarding, title: "Welcome to Flow", size: NSSize(width: 560, height: 480), minSize: nil, resizable: false, autosave: nil),
        WindowSpec(kind: .history, title: "History", size: NSSize(width: 820, height: 560), minSize: NSSize(width: 640, height: 400), resizable: true, autosave: "HistoryWindow"),
        WindowSpec(kind: .dictionary, title: "Dictionary", size: NSSize(width: 520, height: 440), minSize: NSSize(width: 420, height: 320), resizable: true, autosave: "DictionaryWindow"),
        WindowSpec(kind: .settings, title: "Settings", size: NSSize(width: 560, height: 520), minSize: nil, resizable: false, autosave: nil),
    ]

    static func spec(_ kind: WindowKind) -> WindowSpec { all.first { $0.kind == kind }! }
}

/// Owns the four SwiftUI windows. Sizes come from `WindowSpec`; SwiftUI never drives the window size.
@MainActor
final class WindowManager {
    private(set) var windows: [WindowKind: NSWindow] = [:]
    /// The app that was frontmost before one of ours ("Add current app" in Settings → Apps).
    private(set) var previousApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.previousApp = app }
        }
    }

    func show(_ kind: WindowKind) {
        let w = windows[kind] ?? make(kind)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: WindowKind) { windows[kind]?.close() }

    func make(_ kind: WindowKind) -> NSWindow {
        let spec = WindowSpec.spec(kind)
        let root: AnyView
        switch kind {
        case .onboarding: root = AnyView(OnboardingView(onFinish: { [weak self] in self?.close(.onboarding) }))
        case .history: root = AnyView(HistoryView())
        case .dictionary: root = AnyView(DictionaryView())
        case .settings: root = AnyView(SettingsView(onHeight: { [weak self] h in self?.resize(.settings, height: h) }))
        }
        let hc = NSHostingController(rootView: root.environmentObject(AppState.shared))
        // Never let SwiftUI's ideal size drive the window. Resizable windows take their minimum from the root frame.
        hc.sizingOptions = spec.resizable ? [.minSize] : []
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if spec.resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: spec.size), styleMask: style, backing: .buffered, defer: false)
        w.title = spec.title
        w.isReleasedWhenClosed = false
        w.contentViewController = hc
        w.setContentSize(spec.size)
        if let m = spec.minSize { w.contentMinSize = m; w.minSize = w.frameRect(forContentRect: NSRect(origin: .zero, size: m)).size }
        var restored = false
        if let name = spec.autosave {
            restored = w.setFrameUsingName(name)
            w.setFrameAutosaveName(name)
        }
        if !restored { Self.center(w, on: .underMouse) }
        Self.clampOnScreen(w)
        windows[kind] = w
        return w
    }

    /// Settings: fixed width, height per tab, animated.
    func resize(_ kind: WindowKind, height: CGFloat) {
        guard let w = windows[kind] else { return }
        let current = w.contentRect(forFrameRect: w.frame)
        guard abs(current.height - height) > 0.5 else { return }
        var content = current
        content.origin.y = current.maxY - height
        content.size.height = height
        w.setFrame(w.frameRect(forContentRect: content), display: true, animate: w.isVisible)
        Self.clampOnScreen(w)
    }

    static func center(_ w: NSWindow, on screen: NSScreen) {
        let v = screen.visibleFrame
        var f = w.frame
        if f.height > v.height * 0.9 { f.size.height = floor(v.height * 0.9) }
        f.origin = NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2)
        w.setFrame(f, display: false)
    }

    static func clampOnScreen(_ w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = w.frame
        if f.height > v.height * 0.9 { f.size.height = floor(v.height * 0.9) }
        f.origin.x = min(max(f.origin.x, v.minX), max(v.minX, v.maxX - f.width))
        f.origin.y = min(max(f.origin.y, v.minY), max(v.minY, v.maxY - f.height))
        if f != w.frame { w.setFrame(f, display: false) }
    }
}
