import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Keep blocking audio work and its deadline off Swift's cooperative executor.
/// A semaphore wait in the calling test can starve the Tasks delivering the
/// very events that the audio worker is waiting for, especially on small runners.
func runWithWatchdog<T>(_ label: String, timeout: TimeInterval,
                        _ body: @escaping () -> T) async -> T? {
    await withCheckedContinuation { continuation in
        let box = WatchdogResult<T>()
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            box.value = body()
            done.signal()
        }
        worker.name = "watchdog-body-\(label)"
        worker.stackSize = 1 << 21
        worker.start()
        // Only read the result after the semaphore establishes that the worker
        // finished. A timed-out worker may still write its private box later.
        DispatchQueue.global().async {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                // Print here, on the timeout thread, not only after the test
                // task resumes: if the cooperative pool is starved (the
                // failure mode behind the silent 37-minute hang in
                // outgoingDeckStaysSilentAfterTransition), the resumption
                // below may wait indefinitely, and without this line the log
                // shows nothing at all. The sample + Issue.record still run
                // on the test task via withWatchdog once it resumes.
                print("=== WATCHDOG TIMEOUT (\(label)): body did not finish within \(timeout)s ===")
                fflush(stdout)
                continuation.resume(returning: nil)
            } else {
                continuation.resume(returning: box.value)
            }
        }
    }
}

private final class WatchdogResult<T>: @unchecked Sendable {
    var value: T?
}
