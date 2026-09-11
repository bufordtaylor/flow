import AppKit
import FlowCore
import SwiftUI

/// The pill. Never becomes key or main: the target app keeps keyboard focus the whole time.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case listening(level: Float, interim: String)
        case compiling
        case transcribing
        case cleaning
        case done(String)
        case error(String)
    }
    @Published var phase: Phase = .listening(level: 0, interim: "")
    @Published var levels: [Float] = Array(repeating: 0, count: 12)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .listening(_, let interim):
                LevelMeter(levels: model.levels)
                Text(interim.isEmpty ? "Listening…" : interim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(interim.isEmpty ? .secondary : .primary)
            case .compiling:
                ProgressView().controlSize(.small)
                Text("Compiling model…")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            case .cleaning:
                ProgressView().controlSize(.small)
                Text("Cleaning… (Esc to skip)")
            case .done(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).lineLimit(3)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(msg).foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}

struct LevelMeter: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(3, CGFloat(min(1, levels[i] * 6)) * 20))
            }
        }
        .frame(width: 58, height: 20)
    }
}

@MainActor
final class OverlayController {
    static let maxWidth: CGFloat = 420
    static let minWidth: CGFloat = 200
    static let minHeight: CGFloat = 44
    static let maxHeight: CGFloat = 100

    let panel: OverlayPanel
    let model = OverlayModel()
    private let hosting: NSHostingController<OverlayView>
    private var hideTask: Task<Void, Never>?

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: Self.minHeight),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        hosting = NSHostingController(rootView: OverlayView(model: model))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
    }

    func show(_ phase: OverlayModel.Phase) {
        hideTask?.cancel()
        if case .listening(let level, _) = phase {
            var l = model.levels
            l.removeFirst()
            l.append(level)
            model.levels = l
        }
        model.phase = phase
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
        switch phase {
        case .done: scheduleHide(ms: 800)
        case .error: scheduleHide(ms: 3000)
        default: break
        }
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
        model.levels = Array(repeating: 0, count: 12)
    }

    private func scheduleHide(ms: Int) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Width from the text, clamped; top center of the screen that has the frontmost app's window (kept off
    /// the bottom so it never covers the caret).
    func layout() {
        let screen = Self.screenOfFrontmostWindow()
        let maxW = min(Self.maxWidth, screen.frame.width - 40)
        let fitting = hosting.sizeThatFits(in: NSSize(width: maxW, height: Self.maxHeight))
        var w = min(maxW, max(Self.minWidth, fitting.width))
        var h = Self.minHeight
        if case .listening = model.phase { w = maxW } else {
            let h2 = hosting.sizeThatFits(in: NSSize(width: w, height: Self.maxHeight)).height
            h = min(Self.maxHeight, max(Self.minHeight, h2))
        }
        let x = screen.visibleFrame.midX - w / 2
        let y = screen.visibleFrame.maxY - h - 80
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    static func screenOfFrontmostWindow() -> NSScreen {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return NSScreen.main ?? NSScreen.screens[0]
        }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"], let x = b["X"], let y = b["Y"] {
                // CG coordinates are top-left origin; flip into AppKit space using the primary screen height.
                let primaryH = NSScreen.screens[0].frame.height
                let center = CGPoint(x: x + width / 2, y: primaryH - (y + height / 2))
                if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
