import Foundation

/// NSRunningApplication refreshes termination state on the main run loop.
/// Keep it moving while waiting, without depending on wall-clock adjustments.
enum ApplicationTermination {
    static func wait(timeout: TimeInterval, isTerminated: () -> Bool) -> Bool {
        precondition(Thread.isMainThread)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !isTerminated() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(min(0.1, remaining)))
        }
        return true
    }
}
