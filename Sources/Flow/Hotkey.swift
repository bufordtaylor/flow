import AppKit
import FlowCore

/// A CGEvent tap on its own thread. The callback takes the matcher decision under a lock and hands every
/// side effect to the main queue; it never awaits, never touches the pipeline, and never blocks.
final class HotkeyTap: @unchecked Sendable {
    enum Event { case down, up, cancelSilently, escape }

    private let lock = NSLock()
    private var matcher: HotkeyMatcher
    private var dictating = false
    private var thread: Thread?
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private let timerQueue = DispatchQueue(label: "flow.hotkey.arm", qos: .userInteractive)
    private var armTimer: DispatchSourceTimer?
    static let armDelayMs = 120

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?
    private(set) var isRunning = false

    init(spec: HotkeySpec) { matcher = HotkeyMatcher(spec: spec) }

    var spec: HotkeySpec {
        get { lock.lock(); defer { lock.unlock() }; return matcher.spec }
        set { lock.lock(); matcher = HotkeyMatcher(spec: newValue); lock.unlock() }
    }

    func setDictating(_ d: Bool) {
        lock.lock(); dictating = d; if !d { matcher.reset() }; lock.unlock()
    }

    /// Creates the tap on a private thread. Returns false when macOS refuses (no Accessibility grant).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let done = DispatchSemaphore(value: 0)
        var ok = false
        let t = Thread { [self] in
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: HotkeyTap.callback, userInfo: refcon) else {
                done.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.lock(); self.port = port; self.runLoop = rl; isRunning = true; lock.unlock()
            ok = true
            done.signal()
            CFRunLoopRun()
        }
        t.name = "flow.hotkey.tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        done.wait()
        if ok { Log.info("hotkey", "event tap installed") } else { Log.error("hotkey", "event tap could not be created (Accessibility not granted?)") }
        return ok
    }

    func stop() {
        lock.lock()
        let rl = runLoop; let p = port
        runLoop = nil; port = nil; isRunning = false
        lock.unlock()
        if let p { CGEvent.tapEnable(tap: p, enable: false); CFMachPortInvalidate(p) }
        if let rl { CFRunLoopStop(rl) }
        thread = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.reenable()
            return Unmanaged.passUnretained(event)
        }
        // Our own synthetic Cmd+V: never feed it back through the matcher.
        if event.getIntegerValueField(.eventSourceUserData) == AXInserter.pasteMagic {
            return Unmanaged.passUnretained(event)
        }
        let kind: HotkeyEventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        let swallow = tap.handle(kind: kind, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Microseconds of work: one matcher step under the lock, then dispatch.
    private func handle(kind: HotkeyEventKind, keyCode: Int64, flags: UInt64) -> Bool {
        lock.lock()
        let action = matcher.handle(kind: kind, keyCode: keyCode, flags: flags, dictating: dictating)
        let phase = matcher.phase
        lock.unlock()
        if Log.debugTranscripts, kind == .flagsChanged || action != .ignore {
            Log.info("hotkey", "\(kind) key=\(keyCode) flags=0x\(String(flags & HotkeyMatcher.relevantMask, radix: 16)) -> \(action) phase=\(phase)")
        }
        switch action {
        case .ignore: return false
        case .arm: startArmTimer(); return false
        case .disarm: cancelArmTimer(); return false
        case .down(let swallow): deliver(.down); return swallow
        case .up(let swallow): deliver(.up); return swallow
        case .cancelSilently: deliver(.cancelSilently); return false
        case .escape: deliver(.escape); return true
        case .swallow: return true
        }
    }

    private func deliver(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func startArmTimer() {
        timerQueue.async { [self] in
            armTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: timerQueue)
            t.schedule(deadline: .now() + .milliseconds(HotkeyTap.armDelayMs))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let action = self.matcher.armTimerFired()
                self.lock.unlock()
                if case .down = action { self.deliver(.down) }
            }
            t.resume()
            armTimer = t
        }
    }

    private func cancelArmTimer() {
        timerQueue.async { [self] in armTimer?.cancel(); armTimer = nil }
    }

    /// Called when macOS disables the tap (timeout / user input). Re-enabling in a tight loop while the
    /// system is starving the tap thread keeps the keyboard frozen, so back off: after too many timeouts in
    /// a short window, stop the tap entirely and report it, which frees the keyboard. A rare, isolated
    /// timeout just re-enables.
    private var recentTimeouts: [Date] = []
    static let timeoutWindowSeconds: TimeInterval = 2
    static let timeoutGiveUpCount = 2
    /// Called on the main queue when the tap gives up so the app can free the keyboard and warn the user.
    var onTapGaveUp: (() -> Void)?

    private func reenable() {
        lock.lock()
        let now = Date()
        recentTimeouts.append(now)
        recentTimeouts.removeAll { now.timeIntervalSince($0) > Self.timeoutWindowSeconds }
        let giveUp = recentTimeouts.count >= Self.timeoutGiveUpCount
        let p = port
        lock.unlock()
        guard let p else { return }
        if giveUp {
            // Disable the tap and tear it down so every keystroke flows normally again.
            CGEvent.tapEnable(tap: p, enable: false)
            Log.error("hotkey", "tap disabled repeatedly under load; giving up to keep the keyboard responsive")
            DispatchQueue.main.async { [weak self] in self?.onTapGaveUp?(); self?.stop() }
            return
        }
        CGEvent.tapEnable(tap: p, enable: true)
        Log.info("hotkey", "tap re-enabled after macOS disabled it")
    }
}
