import Foundation
import MetricKit
import os

/// Anything MetricKit can serialize. `MXMetricPayload` / `MXDiagnosticPayload` conform as-is.
public protocol JSONPayload {
    func jsonRepresentation() -> Data
}

extension MXMetricPayload: JSONPayload {}
extension MXDiagnosticPayload: JSONPayload {}

/// Writes payloads as `<kind>-<timestamp>-<id>.json` into a directory (default `Library/Perf/`).
public struct PayloadWriter: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case metric, diagnostic
    }

    public let directory: URL

    public init(directory: URL = PayloadWriter.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        URL.libraryDirectory.appending(path: "Perf", directoryHint: .isDirectory)
    }

    @discardableResult
    public func write(_ payload: some JSONPayload, kind: Kind, date: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let id = UUID().uuidString.prefix(8)
        let url = directory.appending(path: "\(kind.rawValue)-\(stamp)-\(id).json", directoryHint: .notDirectory)
        try payload.jsonRepresentation().write(to: url, options: .atomic)
        return url
    }

    /// Written payload files, oldest first.
    public func files(kind: Kind? = nil) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                url.pathExtension == "json" && (kind.map { url.lastPathComponent.hasPrefix($0.rawValue + "-") } ?? true)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Receives MetricKit payloads (launch, animation/hitch, hang, ...) on a background queue and dumps them to disk.
/// Payloads are delivered on device roughly daily, or via Xcode > Debug > Simulate MetricKit Payloads.
/// `MXMetricManagerSubscriber` is "to be deprecated" for iOS 27's `MetricManager`; kept while deployment target is 26.
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private let writer: PayloadWriter
    private static let log = Logger(subsystem: Signpost.subsystem, category: "metrickit")

    init(writer: PayloadWriter) {
        self.writer = writer
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            save(payload, kind: .metric)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            save(payload, kind: .diagnostic)
        }
    }

    private func save(_ payload: some JSONPayload, kind: PayloadWriter.Kind) {
        do {
            let url = try writer.write(payload, kind: kind)
            Self.log.info("wrote \(kind.rawValue, privacy: .public) payload \(url.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.error("failed to write \(kind.rawValue, privacy: .public) payload: \(error, privacy: .public)")
        }
    }
}
