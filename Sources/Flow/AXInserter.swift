import AppKit
import ApplicationServices
import FlowCore

/// Puts text at the caret of whatever has focus. Every AX and pasteboard call runs on the main thread:
/// when the focused element is one of our own fields, the AX set runs AppKit text editing in-process, and
/// AppKit traps if that happens off the main queue.
@MainActor
final class AXInserter: TextInserter {
    /// Tags our synthetic Cmd+V so the hotkey tap passes it through instead of feeding it back.
    nonisolated static let pasteMagic: Int64 = 0x464C_4F57  // "FLOW"
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]

    var onNoTextField: (() -> Void)?
    var onSecureField: (() -> Void)?

    nonisolated init() {}

    func insert(_ text: String) async -> InsertResult {
        var text = text
        if WorkspaceFrontmost.isTerminalFrontmost, text.contains("\n") {
            // A newline in a terminal runs the line. Paste one line instead.
            text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if !text.hasSuffix(" ") && Settings.shared.trailingSpace { text += " " }
        }

        guard let element = focusedElement() else { return clipboardOnly(text) }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if role == "AXSecureTextField" {
            onSecureField?()
            return .failed("secure field")
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        let focused = (attribute(element, kAXFocusedAttribute) as? Bool) ?? false
        let looksLikeText = Self.textRoles.contains(role) || attribute(element, kAXNumberOfCharactersAttribute) != nil
        guard looksLikeText || (focused && settable.boolValue) else { return clipboardOnly(text) }

        if settable.boolValue {
            let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if err == .success, let value = attribute(element, kAXValueAttribute) as? String {
                // Many browser and Electron fields report success without inserting, so read back.
                // ponytail: compare up to 2 MB; past that assume the paste path (avoids a double insert on big docs).
                if value.utf16.count <= 2_000_000, value.contains(text) || value.contains(text.trimmingCharacters(in: .whitespaces)) {
                    return .ax
                }
            }
        }
        return await paste(text)
    }

    // MARK: Paths

    private func paste(_ text: String) async -> InsertResult {
        let pb = NSPasteboard.general
        let snapshot: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        defer { restore(snapshot, on: pb) }
        let posted = Self.postCommandV()
        try? await Task.sleep(nanoseconds: 150_000_000)
        return posted ? .paste : .failed("couldn't post the paste keystroke")
    }

    private func restore(_ snapshot: [[(NSPasteboard.PasteboardType, Data)]], on pb: NSPasteboard) {
        // An empty previous clipboard: leave our text rather than nothing.
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in entries { item.setData(d, forType: t) }
            return item
        }
        pb.clearContents()
        if !pb.writeObjects(items) {
            // Restoring failed: put the dictated text back rather than leave the clipboard empty.
            pb.clearContents()
            pb.setString(items.first?.string(forType: .string) ?? "", forType: .string)
        }
    }

    private func clipboardOnly(_ text: String) -> InsertResult {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        onNoTextField?()
        return .clipboardOnly
    }

    static func postCommandV() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return false }
        for e in [down, up] {
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: pasteMagic)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: AX helpers

    private func focusedElement() -> AXUIElement? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref
    }
}
