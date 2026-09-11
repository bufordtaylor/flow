import AppKit
import FlowCore
import SwiftUI

/// `Flow --check-windows`: open every window, wait a second, print sizes, screenshot, exit 1 on any miss.
@MainActor
enum WindowCheck {
    struct Expected { let name: String; let size: NSSize; let min: NSSize; let resizable: Bool }

    static let table: [Expected] = [
        Expected(name: "onboarding", size: NSSize(width: 560, height: 480), min: NSSize(width: 560, height: 480), resizable: false),
        Expected(name: "overlay", size: NSSize(width: 420, height: 44), min: NSSize(width: 200, height: 44), resizable: false),
        Expected(name: "history", size: NSSize(width: 820, height: 560), min: NSSize(width: 640, height: 400), resizable: true),
        Expected(name: "dictionary", size: NSSize(width: 520, height: 440), min: NSSize(width: 420, height: 320), resizable: true),
        Expected(name: "settings", size: NSSize(width: 560, height: 520), min: NSSize(width: 560, height: 520), resizable: false),
    ]

    static func run() {
        ClipReport.shared.enabled = true
        for name in WindowSpec.all.map(\.autosave).compactMap({ $0 }) { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let c = AppCoordinator.shared
        let overlay = c.overlay
        for k in WindowKind.allCases { c.windows.show(k) }
        overlay.show(.listening(level: 0.6, interim: "this is a long interim transcript so the pill measures at its full width for the check"))
        let outDir = URL(fileURLWithPath: "build/windows")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            var failed = false
            for e in table {
                let window: NSWindow? = e.name == "overlay" ? overlay.panel : c.windows.windows[WindowKind(rawValue: e.name)!]
                guard let w = window else { print("WINDOW \(e.name) missing"); failed = true; continue }
                let content = w.contentRect(forFrameRect: w.frame).size
                let minSize = e.resizable ? w.contentMinSize : content
                let screen = w.screen?.frame.size ?? .zero
                let clippedViews = walk(w.contentView) + ClipReport.shared.clipped(prefix: e.name + "/")
                print("WINDOW \(e.name) \(Int(content.width))x\(Int(content.height)) min=\(Int(minSize.width))x\(Int(minSize.height)) screen=\(Int(screen.width))x\(Int(screen.height)) clipped=\(clippedViews.count)")
                for v in clippedViews { print("  clipped: \(v)") }
                let sizeOK = abs(content.width - e.size.width) <= 2 && abs(content.height - e.size.height) <= 2
                let minOK = e.resizable ? (abs(minSize.width - e.min.width) <= 2 && abs(minSize.height - e.min.height) <= 2) : (w.styleMask.contains(.resizable) == false)
                let visible = w.screen?.visibleFrame ?? .zero
                let onScreen = visible.contains(w.frame) || (e.name == "overlay" && visible.intersects(w.frame))
                if !sizeOK { print("  size mismatch: expected \(Int(e.size.width))x\(Int(e.size.height))") }
                if !minOK { print("  minimum mismatch: expected \(Int(e.min.width))x\(Int(e.min.height)) resizable=\(e.resizable)") }
                if !onScreen { print("  off-screen: frame=\(w.frame) visible=\(visible)") }
                if !sizeOK || !minOK || !onScreen || !clippedViews.isEmpty { failed = true }
                screenshot(w, to: outDir.appendingPathComponent("\(e.name).png"))
            }
            print(failed ? "CHECK FAILED" : "CHECK OK")
            exit(failed ? 1 : 0)
        }
    }

    /// Views whose intrinsic size is larger than the frame they got. Scroll and table internals are skipped.
    static func walk(_ view: NSView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if view is NSScrollView || view is NSTableView || view is NSClipView { return [] }
        let i = view.intrinsicContentSize
        let f = view.frame.size
        if view is NSTextField || view is NSButton {
            if (i.width != NSView.noIntrinsicMetric && i.width > f.width + 1) || (i.height != NSView.noIntrinsicMetric && i.height > f.height + 1) {
                out.append("\(type(of: view)) intrinsic=\(Int(i.width))x\(Int(i.height)) frame=\(Int(f.width))x\(Int(f.height))")
            }
        }
        for s in view.subviews { out += walk(s) }
        return out
    }

    static func screenshot(_ w: NSWindow, to url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), url.path]
        try? p.run()
        p.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size < 2000, let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        // screencapture needs Screen Recording for the invoking terminal; fall back to rendering our own view.
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
