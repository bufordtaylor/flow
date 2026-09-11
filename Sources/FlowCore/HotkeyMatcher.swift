import Foundation

/// A hotkey is either a lone modifier (key code of the modifier key, e.g. 61 = right ⌥) or a key plus modifier flags.
public struct HotkeySpec: Sendable, Equatable, Codable {
    public var keyCode: Int64
    /// CGEventFlags raw value, masked to `HotkeyMatcher.relevantMask`.
    public var modifiers: UInt64

    public init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & HotkeyMatcher.relevantMask
    }

    public static let rightOption = HotkeySpec(keyCode: 61, modifiers: 0)

    public var isModifierOnly: Bool { HotkeyMatcher.modifierBit(forKeyCode: keyCode) != nil }

    public var displayString: String {
        var parts: [String] = []
        if modifiers & HotkeyMatcher.control != 0 { parts.append("⌃") }
        if modifiers & HotkeyMatcher.option != 0 { parts.append("⌥") }
        if modifiers & HotkeyMatcher.shift != 0 { parts.append("⇧") }
        if modifiers & HotkeyMatcher.command != 0 { parts.append("⌘") }
        if modifiers & HotkeyMatcher.fn != 0 { parts.append("fn") }
        if let name = HotkeyMatcher.modifierKeyName(keyCode) { return name }
        return (parts.joined() + " " + HotkeyMatcher.keyName(keyCode)).trimmingCharacters(in: .whitespaces)
    }
}

public enum HotkeyEventKind: Sendable { case keyDown, keyUp, flagsChanged }

public enum HotkeyAction: Sendable, Equatable {
    /// Nothing to do; pass the event through.
    case ignore
    /// Modifier appeared alone: start the 120 ms arm timer.
    case arm
    /// Something else happened inside the arm window: cancel the timer, no side effects.
    case disarm
    /// The real key-down. `swallow` is true only for chord hotkeys.
    case down(swallow: Bool)
    /// The real key-up.
    case up(swallow: Bool)
    /// Another key while held: it was a shortcut. Cancel silently and pass the event through.
    case cancelSilently
    /// Escape while dictating. Swallow it.
    case escape
    /// Auto-repeat of a chord's own key while held: swallow, do nothing.
    case swallow
}

/// Pure three-phase state machine: idle → armed → held. No timers, no side effects; the caller owns both.
public struct HotkeyMatcher: Sendable {
    public static let shift: UInt64 = 0x20000
    public static let control: UInt64 = 0x40000
    public static let option: UInt64 = 0x80000
    public static let command: UInt64 = 0x100000
    public static let fn: UInt64 = 0x800000
    public static let relevantMask: UInt64 = shift | control | option | command | fn
    public static let escapeKeyCode: Int64 = 53

    public enum Phase: Sendable, Equatable { case idle, armed, held }

    public private(set) var phase: Phase = .idle
    public var spec: HotkeySpec

    public init(spec: HotkeySpec) { self.spec = spec }

    public static func modifierBit(forKeyCode code: Int64) -> UInt64? {
        switch code {
        case 54, 55: return command
        case 56, 60: return shift
        case 58, 61: return option
        case 59, 62: return control
        case 63: return fn
        default: return nil
        }
    }

    public static func modifierKeyName(_ code: Int64) -> String? {
        switch code {
        case 54: return "⌘ (right)"
        case 55: return "⌘ (left)"
        case 56: return "⇧ (left)"
        case 60: return "⇧ (right)"
        case 58: return "⌥ (left)"
        case 61: return "⌥ (right)"
        case 59: return "⌃ (left)"
        case 62: return "⌃ (right)"
        case 63: return "fn"
        default: return nil
        }
    }

    public static func keyName(_ code: Int64) -> String {
        let names: [Int64: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→",
            125: "↓", 126: "↑", 0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
            37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return names[code] ?? "Key \(code)"
    }

    public mutating func handle(kind: HotkeyEventKind, keyCode: Int64, flags rawFlags: UInt64, dictating: Bool) -> HotkeyAction {
        let flags = rawFlags & Self.relevantMask

        if kind == .keyDown && keyCode == Self.escapeKeyCode && dictating {
            phase = .idle
            return .escape
        }

        if let bit = Self.modifierBit(forKeyCode: spec.keyCode) {
            return handleModifierOnly(kind: kind, keyCode: keyCode, flags: flags, bit: bit)
        }
        return handleChord(kind: kind, keyCode: keyCode, flags: flags)
    }

    /// Called when the 120 ms arm timer fires. Returns `.down` if still armed.
    public mutating func armTimerFired() -> HotkeyAction {
        guard phase == .armed else { return .ignore }
        phase = .held
        return .down(swallow: false)
    }

    public mutating func reset() { phase = .idle }

    private mutating func handleModifierOnly(kind: HotkeyEventKind, keyCode: Int64, flags: UInt64, bit: UInt64) -> HotkeyAction {
        switch phase {
        case .idle:
            // Exactly our bit, from our key, with no other modifier held.
            if kind == .flagsChanged && keyCode == spec.keyCode && flags == bit {
                phase = .armed
                return .arm
            }
            return .ignore
        case .armed:
            // Anything at all inside the window means it was a combo or a tap: zero side effects.
            phase = .idle
            return .disarm
        case .held:
            if kind == .flagsChanged && keyCode == spec.keyCode && flags & bit == 0 {
                phase = .idle
                return .up(swallow: false)
            }
            if kind == .keyDown {
                phase = .idle
                return .cancelSilently
            }
            return .ignore
        }
    }

    private mutating func handleChord(kind: HotkeyEventKind, keyCode: Int64, flags: UInt64) -> HotkeyAction {
        switch phase {
        case .idle, .armed:
            if kind == .keyDown && keyCode == spec.keyCode && flags == spec.modifiers {
                phase = .held
                return .down(swallow: true)
            }
            return .ignore
        case .held:
            if keyCode == spec.keyCode {
                if kind == .keyUp { phase = .idle; return .up(swallow: true) }
                return .swallow
            }
            if kind == .keyDown {
                phase = .idle
                return .cancelSilently
            }
            return .ignore
        }
    }
}
