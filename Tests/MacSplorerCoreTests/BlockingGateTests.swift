import Foundation
import Testing
@testable import MacSplorerCore

/// The gate that keeps Recents' blocking Spotlight query off Swift's shared threads.
@Suite struct BlockingGateTests {
    @Test func returnsTheWorksResult() async throws {
        let gate = BlockingGate<Int>(label: "test")
        let value = try await gate.run(timeout: 5) { 42 }
        #expect(value == 42)
    }

    @Test func aStuckJobTimesOutInsteadOfHanging() async {
        let gate = BlockingGate<Int>(label: "test")
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        await #expect(throws: RecentsError.self) {
            try await gate.run(timeout: 0.3) { release.wait(); return 1 }
        }
        #expect(Date().timeIntervalSince(started) < 3)
        release.signal()
    }

    @Test func callersWhileRunningShareOneJob() async throws {
        let gate = BlockingGate<Int>(label: "test")
        let runs = Counter()
        async let a = gate.run(timeout: 5) { runs.bump(); Thread.sleep(forTimeInterval: 0.3); return 7 }
        try await Task.sleep(nanoseconds: 50_000_000)
        async let b = gate.run(timeout: 5) { runs.bump(); return 8 }
        let results = try await [a, b]
        #expect(results == [7, 7])
        #expect(runs.value == 1)
    }

    /// Many more stuck jobs than there are cores must not starve other async work.
    @Test func stuckJobsDontStarveOtherTasks() async throws {
        let gate = BlockingGate<Int>(label: "test")
        let release = DispatchSemaphore(value: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { _ = try? await gate.run(timeout: 0.5) { release.wait(); return 0 } }
            }
            // While those wait, ordinary async work still gets a thread.
            group.addTask {
                let value = await Task.detached { 1 + 1 }.value
                #expect(value == 2)
            }
        }
        release.signal()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
