import Foundation

/// Measures working time for a deadline, excluding time spent waiting for the
/// user (for example an approval dialog). Clocks nest: pausing an inner clock
/// also pauses every enclosing one, so a turn deadline and a tool deadline
/// both ignore the same approval wait.
public final class PHKDeadlineClock: @unchecked Sendable {
    @TaskLocal public static var current: PHKDeadlineClock?

    private let parent: PHKDeadlineClock?
    private let lock = NSLock()
    private let startedAt = ContinuousClock.now
    private var pausedDepth = 0
    private var pausedSince: ContinuousClock.Instant?
    private var pausedTotal: Duration = .zero

    public init(parent: PHKDeadlineClock? = PHKDeadlineClock.current) {
        self.parent = parent
    }

    public var workElapsed: Duration {
        lock.withLock {
            let now = ContinuousClock.now
            let paused = pausedTotal + (pausedSince.map { $0.duration(to: now) } ?? .zero)
            return startedAt.duration(to: now) - paused
        }
    }

    public var isPaused: Bool { lock.withLock { pausedDepth > 0 } }

    func pause() {
        lock.withLock {
            if pausedDepth == 0 { pausedSince = .now }
            pausedDepth += 1
        }
        parent?.pause()
    }

    func resume() {
        lock.withLock {
            pausedDepth = max(0, pausedDepth - 1)
            if pausedDepth == 0, let since = pausedSince {
                pausedTotal += since.duration(to: .now)
                pausedSince = nil
            }
        }
        parent?.resume()
    }

    /// Runs `body` without charging its duration to any enclosing deadline.
    public static func excludingUserWait<T>(_ body: () async throws -> T) async rethrows -> T {
        // A cancelled straggler (its deadline already passed) must not pause
        // the enclosing turn's deadline.
        guard let clock = current, !Task.isCancelled else { return try await body() }
        clock.pause()
        defer { clock.resume() }
        return try await body()
    }

    /// Sleeps until `limit` of working time has elapsed on this clock.
    public func sleep(untilWorkElapsed limit: Duration) async throws {
        while true {
            let remaining = limit - workElapsed
            if remaining <= .zero && !isPaused { return }
            try await Task.sleep(for: max(remaining, .milliseconds(100)))
        }
    }
}

public enum PHKDeadline {
    /// Runs `operation` and returns as soon as it finishes, `limit` of working
    /// time elapses, or the caller is cancelled — whichever happens first.
    /// Unlike a task group, this does not wait for an operation that ignores
    /// cancellation; such a straggler is cancelled and left to finish alone.
    public static func run<T: Sendable>(
        limit: Duration,
        onTimeout: @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = PHKDeadlineClock()
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                race.install(continuation)
                let work = Task {
                    do {
                        let value = try await PHKDeadlineClock.$current.withValue(clock) { try await operation() }
                        race.finish(.success(value))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task {
                    do { try await clock.sleep(untilWorkElapsed: limit) } catch { return }
                    race.finish(.failure(onTimeout()))
                }
                race.track(work, timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<T, Error>) {
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }

        func track(_ values: Task<Void, Never>...) {
            let finished = lock.withLock { () -> Bool in
                if result != nil { return true }
                tasks += values
                return false
            }
            if finished { values.forEach { $0.cancel() } }
        }

        func finish(_ value: Result<T, Error>) {
            let (pending, running): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = lock.withLock {
                guard result == nil else { return (nil, []) }
                result = value
                defer { continuation = nil; tasks = [] }
                return (continuation, tasks)
            }
            running.forEach { $0.cancel() }
            pending?.resume(with: value)
        }
    }
}
