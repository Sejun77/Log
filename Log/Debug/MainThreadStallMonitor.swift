#if DEBUG
import Foundation
import QuartzCore

/// Debug-only record of long main-thread passes, for measuring interaction
/// latency on a real device.
///
/// **Off by default.** It runs only when launched with `--stall-monitor`, for
/// example from an Xcode scheme, and never in a unit-test host. When off, nothing
/// is installed: the only cost is the launch-time argument check.
///
/// It writes one JSON object per line to `Library/Caches/Diagnostics`. It knows
/// nothing about the model layer, so it cannot read, seed, reset or change workout
/// data. Compiled out of Release builds.
@MainActor
final class MainThreadStallMonitor {
    static let launchArgument = "--stall-monitor"
    static let thresholdMs = 50.0

    /// Kept alive for the life of the process once installed.
    private(set) static var installed: MainThreadStallMonitor?

    static func isRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains(launchArgument)
            && environment["XCTestConfigurationFilePath"] == nil
    }

    static func installIfRequested() {
        guard isRequested(), installed == nil, let url = defaultFileURL() else { return }
        let monitor = MainThreadStallMonitor(fileURL: url)
        monitor.start()
        installed = monitor
    }

    static func defaultFileURL(now: Date = Date()) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("stalls-\(Int(now.timeIntervalSince1970)).jsonl")
    }

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "Gym.Log.StallMonitor.io", qos: .utility)
    private var fileHandle: FileHandle?
    private var wakeObserver: CFRunLoopObserver?
    private var sleepObserver: CFRunLoopObserver?
    private var passStart: CFTimeInterval?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func start() {
        guard wakeObserver == nil else { return }
        openFile()

        // A pass runs from the run loop waking until it is next about to sleep.
        // The extreme orders put these observers outside all the pass's other work.
        let wake = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.passStart = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.endPass() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
        wakeObserver = wake
        sleepObserver = sleep
    }

    /// Stops recording, and returns once everything recorded is on disk.
    func stop() {
        if let wakeObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), wakeObserver, .commonModes) }
        if let sleepObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), sleepObserver, .commonModes) }
        wakeObserver = nil
        sleepObserver = nil
        passStart = nil
        ioQueue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func openFile() {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    private func endPass() {
        guard let start = passStart else { return }
        passStart = nil
        let ms = (CACurrentMediaTime() - start) * 1000
        guard ms >= Self.thresholdMs else { return }
        write(["type": "stall", "ms": ms, "wall": Date().timeIntervalSince1970])
    }

    /// The file is written off the main thread so recording adds no stall of its own.
    private func write(_ record: [String: Any]) {
        ioQueue.async { [fileHandle] in
            guard var line = try? JSONSerialization.data(withJSONObject: record) else { return }
            line.append(0x0A)
            try? fileHandle?.write(contentsOf: line)
        }
    }
}
#endif
