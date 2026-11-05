import XCTest

@testable import Log

@MainActor
final class MainThreadStallMonitorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var fileURL: URL { directory.appendingPathComponent("stalls.jsonl") }

    /// Blocks the main thread inside one run-loop pass, then lets that pass finish.
    /// The delay lets the run loop sleep first, because a pass is timed from a wake.
    private func stallMainThread(forSeconds seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Thread.sleep(forTimeInterval: seconds)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds + 0.4))
    }

    private func recordedStalls() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    // MARK: - Activation

    func test_isOffByDefault() {
        XCTAssertFalse(MainThreadStallMonitor.isRequested(arguments: ["Log"], environment: [:]))
    }

    func test_launchArgumentTurnsItOn() {
        XCTAssertTrue(
            MainThreadStallMonitor.isRequested(
                arguments: ["Log", MainThreadStallMonitor.launchArgument], environment: [:]))
    }

    func test_neverRunsInATestHost() {
        XCTAssertFalse(
            MainThreadStallMonitor.isRequested(
                arguments: ["Log", MainThreadStallMonitor.launchArgument],
                environment: ["XCTestConfigurationFilePath": "/tmp/config"]))

        MainThreadStallMonitor.installIfRequested()
        XCTAssertNil(MainThreadStallMonitor.installed)
    }

    /// Caches holds nothing the app depends on, and is apart from the store.
    func test_writesToCachesOnly() throws {
        let url = try XCTUnwrap(MainThreadStallMonitor.defaultFileURL())
        XCTAssertTrue(url.path.contains("/Library/Caches/Diagnostics/"), url.path)
    }

    // MARK: - Recording

    func test_recordsALongPass() throws {
        let monitor = MainThreadStallMonitor(fileURL: fileURL)
        monitor.start()

        stallMainThread(forSeconds: 0.15)
        monitor.stop()

        let stall = try XCTUnwrap(
            recordedStalls().first { ($0["ms"] as? Double ?? 0) >= 140 },
            "The 150 ms pass was not recorded.")
        XCTAssertEqual(stall["type"] as? String, "stall")
        XCTAssertNotNil(stall["wall"] as? Double)
    }

    func test_recordsNothingAfterStop() throws {
        let monitor = MainThreadStallMonitor(fileURL: fileURL)
        monitor.start()
        monitor.stop()

        stallMainThread(forSeconds: 0.15)

        XCTAssertEqual(try recordedStalls().count, 0)
    }
}
