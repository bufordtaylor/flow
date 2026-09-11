import Foundation

public protocol Clock: Sendable {
    func now() -> Date
    func sleep(ms: Int) async
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }
}

public struct TimeoutError: Error, Sendable, Equatable {
    public let ms: Int
    public init(ms: Int) { self.ms = ms }
}

/// Races `operation` against the clock. Resumes exactly once from whichever finishes first and
/// abandons the loser, so a model call that ignores cancellation never holds the caller past the deadline.
/// (A `withThrowingTaskGroup` race awaits every child before returning, which is why this exists.)
public func withTimeout<T: Sendable>(ms: Int, clock: Clock, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = OneShot<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            gate.arm(cont)
            let work = Task {
                do { gate.resume(.success(try await operation())) }
                catch { gate.resume(.failure(error)) }
            }
            let timer = Task {
                await clock.sleep(ms: ms)
                gate.resume(.failure(TimeoutError(ms: ms)))
            }
            gate.setTasks(work: work, timer: timer)
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
}

private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func arm(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending { lock.unlock(); c.resume(with: pending); return }
        cont = c
        lock.unlock()
    }

    func setTasks(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.work = work; self.timer = timer
        let done = cont == nil && pending != nil
        lock.unlock()
        if done { work.cancel(); timer.cancel() }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard pending == nil else { lock.unlock(); return }
        pending = result
        let c = cont; cont = nil
        let w = work, t = timer
        lock.unlock()
        w?.cancel(); t?.cancel()
        c?.resume(with: result)
    }
}
