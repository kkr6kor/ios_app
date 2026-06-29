import Foundation
import os

/// Protocol-capture + session logging, mirroring the Kotlin `RideDiagnostics`.
/// Everything routes through here so a single in-app log view (or Console.app) is
/// enough to reverse unknown TLVs and field-map telemetry.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private let logger = Logger(subsystem: "com.cairn.dash", category: "diagnostics")
    private let lock = NSLock()
    private var ring: [String] = []
    private let maxEntries = 2000

    private init() {}

    func log(_ tag: String, _ message: String) {
        let line = "[\(tag)] \(message)"
        logger.info("\(line, privacy: .public)")
        lock.lock()
        ring.append(line)
        if ring.count > maxEntries { ring.removeFirst(ring.count - maxEntries) }
        lock.unlock()
    }

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }
}
