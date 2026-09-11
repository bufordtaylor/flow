import AppKit
import SwiftUI

/// `--check-windows` support: SwiftUI views report their ideal vs. actual size here.
@MainActor
final class ClipReport {
    static let shared = ClipReport()
    var enabled = false
    struct Entry { var oneLine: CGSize = .zero; var wrapped: CGSize = .zero; var actual: CGSize = .zero }
    private var entries: [String: Entry] = [:]

    func report(_ key: String, oneLine: CGSize? = nil, wrapped: CGSize? = nil, actual: CGSize? = nil) {
        guard enabled else { return }
        var e = entries[key] ?? Entry()
        if let oneLine { e.oneLine = oneLine }
        if let wrapped { e.wrapped = wrapped }
        if let actual { e.actual = actual }
        entries[key] = e
    }

    /// A label is clipped when the wrapped ideal (at the width it got) is taller than what it got, or when it
    /// is a single line and its one-line ideal is wider than what it got (truncation).
    func clipped(prefix: String) -> [String] {
        entries.filter { $0.key.hasPrefix(prefix) && $0.value.actual != .zero }
            .filter { _, e in
                let cutVertically = e.wrapped != .zero && e.wrapped.height > e.actual.height + 1
                let singleLine = e.oneLine != .zero && e.actual.height < e.oneLine.height * 1.5
                let truncated = singleLine && e.oneLine.width > e.actual.width + 1
                return cutVertically || truncated
            }
            .map { "\($0.key) oneLine=\(Int($0.value.oneLine.width))x\(Int($0.value.oneLine.height)) wrapped=\(Int($0.value.wrapped.width))x\(Int($0.value.wrapped.height)) got=\(Int($0.value.actual.width))x\(Int($0.value.actual.height))" }
            .sorted()
    }

    func reset() { entries = [:] }
}

private struct ClipCheckModifier: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { s in ClipReport.shared.report(key, actual: s) }
            .overlay(alignment: .topLeading) {
                content.fixedSize().hidden().allowsHitTesting(false)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { s in ClipReport.shared.report(key, oneLine: s) }
            }
            .overlay(alignment: .topLeading) {
                content.fixedSize(horizontal: false, vertical: true).hidden().allowsHitTesting(false)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { s in ClipReport.shared.report(key, wrapped: s) }
            }
    }
}

extension View {
    /// Marks a label whose ideal size must fit the space it gets. `window` groups the report per window.
    func clipCheck(_ window: String, _ name: String) -> some View { modifier(ClipCheckModifier(key: "\(window)/\(name)")) }
}

/// Wraps words so each can carry its own context menu (History: right-click a word to add it).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: maxW == .infinity ? width : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
