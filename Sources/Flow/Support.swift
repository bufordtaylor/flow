import AppKit
import FlowCore
import UserNotifications

enum Sounds {
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String) {
        guard Settings.shared.playSounds else { return }
        let sound: NSSound?
        if let c = cache[name] { sound = c } else {
            let url = Bundle.main.url(forResource: name, withExtension: "aiff")
                ?? URL(fileURLWithPath: "Resources/\(name).aiff")
            sound = NSSound(contentsOf: url, byReference: true)
            sound?.volume = 0.3
            cache[name] = sound
        }
        sound?.stop()
        sound?.play()
    }
}

/// UNUserNotificationCenter needs a bundle; when run as a bare binary we just log.
enum Notify {
    private static var asked = false

    static func send(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { Log.info("notify", "\(title): \(body)"); return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if asked { post(); return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { post() } else { Log.info("notify", "notifications not allowed: \(title): \(body)") }
        }
    }
}

extension NSScreen {
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

func openURL(_ s: String) {
    if let u = URL(string: s) { NSWorkspace.shared.open(u) }
}
