import Foundation
import MetricKit
import os

/// Subscribes to MetricKit crash/hang diagnostics so field failures are visible
/// without shipping a third-party crash reporter.
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReporter()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MetricKit")
    private let queue = DispatchQueue(label: "com.arcusis.zerm.metrickit")

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        logger.notice("MetricKit subscriber registered")
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            logger.notice("MetricKit payload received: \(payload.dictionaryRepresentation().description, privacy: .public)")
            DebugLogger.shared.log("MetricKit", "metric payload bytes=\(payload.jsonRepresentation().count)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            logger.error("MetricKit diagnostic received (\(json.count, privacy: .public) bytes)")
            DebugLogger.shared.log("MetricKit", "diagnostic payload bytes=\(json.count)")
            persistDiagnostic(json)
        }
    }

    private func persistDiagnostic(_ data: Data) {
        queue.async {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.arcusis.zerm")
                .appendingPathComponent("Diagnostics")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("metrickit-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: url, options: .atomic)
        }
    }
}
