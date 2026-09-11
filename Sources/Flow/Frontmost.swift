import AppKit
import FlowCore

/// The app that will receive the text. Read at key-down, before any of our windows could steal focus.
struct WorkspaceFrontmost: FrontmostApp {
    var bundleId: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var name: String? { NSWorkspace.shared.frontmostApplication?.localizedName }

    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.mitchellh.ghostty",
    ]

    static var isTerminalFrontmost: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminalBundleIds.contains(id)
    }
}
