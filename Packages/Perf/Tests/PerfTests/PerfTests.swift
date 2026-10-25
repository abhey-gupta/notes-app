import Foundation
@testable import Perf
import Testing

// MARK: - LatencyStats

struct LatencyStatsTests {
    @Test func emptyHasNoPercentiles() {
        let stats = LatencyStats(capacity: 8)
        #expect(stats.p50 == nil)
        #expect(stats.p95 == nil)
    }

    @Test func nearestRankPercentiles() {
        var stats = LatencyStats(capacity: 100)
        for v in (1 ... 100).shuffled() {
            stats.record(Double(v))
        }
        #expect(stats.p50 == 50)
        #expect(stats.p95 == 95)
        #expect(stats.percentile(0) == 1)
        #expect(stats.percentile(1) == 100)
    }

    @Test func singleSample() {
        var stats = LatencyStats(capacity: 4)
        stats.record(7)
        #expect(stats.p50 == 7)
        #expect(stats.p95 == 7)
    }

    @Test func rollingWindowEvictsOldest() {
        var stats = LatencyStats(capacity: 10)
        for _ in 0 ..< 10 {
            stats.record(1000)
        }
        for v in 1 ... 10 {
            stats.record(Double(v))
        }
        #expect(stats.count == 10)
        #expect(stats.p50 == 5)
        #expect(stats.p95 == 10)
    }

    @Test func reset() {
        var stats = LatencyStats(capacity: 4)
        stats.record(1)
        stats.reset()
        #expect(stats.isEmpty)
        #expect(stats.p50 == nil)
    }
}

// MARK: - Signpost

struct SignpostTests {
    @Test func namesAreFixed() {
        #expect(Signpost.allCases.map(\.rawValue) == [
            "launch.firstFrame", "notebook.open", "canvas.firstSharpTile", "canvas.frame", "tile.render",
            "stroke.commit", "doc.checkpoint", "thumb.render", "export.pdf", "pages.overview",
        ])
        #expect(Signpost.subsystem == "com.abhey.notespace")
    }

    @Test func namesAreUnique() {
        let names = Signpost.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    @Test(arguments: Signpost.allCases)
    func staticNameMatchesRawValueAndCategory(_ signpost: Signpost) {
        #expect(signpost.rawValue == "\(signpost.staticName)")
        #expect(signpost.rawValue.hasPrefix(signpost.category.rawValue + "."))
    }

    @Test func intervalsAndEventsDontCrash() {
        for signpost in Signpost.allCases {
            signpost.begin().end()
            signpost.event()
            #expect(signpost.measure { 42 } == 42)
        }
    }
}

// MARK: - FrameStats

struct FrameStatsTests {
    @Test func steady120HzHasNoHitches() throws {
        var stats = FrameStats()
        let dt = 1.0 / 120
        for i in 0 ... 120 {
            let t = Double(i) * dt
            stats.record(timestamp: t, targetTimestamp: t + dt)
        }
        #expect(stats.hitchCount == 0)
        let drained = stats.drainWindow()
        let window = try #require(drained)
        #expect(abs(window.averageMs - 1000.0 / 120) < 0.01)
        #expect(abs(window.fps - 120) < 0.1)
        let empty = stats.drainWindow()
        #expect(empty == nil)
    }

    @Test func droppedFramesCountAsHitches() throws {
        var stats = FrameStats()
        let dt = 1.0 / 120
        let times = [0, 1, 2, 5, 6, 9].map { Double($0) * dt }
        for t in times {
            stats.record(timestamp: t, targetTimestamp: t + dt)
        }
        #expect(stats.hitchCount == 2)
        let drained = stats.drainWindow()
        let window = try #require(drained)
        #expect(abs(window.maxMs - 3 * dt * 1000) < 0.01)
    }
}

// MARK: - PayloadWriter

private struct FakePayload: JSONPayload {
    let json: [String: Any]
    func jsonRepresentation() -> Data {
        (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }
}

struct PayloadWriterTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PerfTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PayloadWriter(directory: dir)
        let payload = FakePayload(json: [
            "applicationLaunchMetrics": ["histogrammedTimeToFirstDrawKey": ["histogramNumBuckets": 1]],
            "animationMetrics": ["scrollHitchTimeRatio": "0.5 ms per s"],
        ])

        let url = try writer.write(payload, kind: .metric, date: Date(timeIntervalSince1970: 0))
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("metric-1970"))
        #expect(url.pathExtension == "json")

        let data = try Data(contentsOf: url)
        #expect(data == payload.jsonRepresentation())
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let animation = try #require(decoded["animationMetrics"] as? [String: String])
        #expect(animation["scrollHitchTimeRatio"] == "0.5 ms per s")
    }

    @Test func listsByKindOldestFirst() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PayloadWriter(directory: dir)
        #expect(try writer.files().isEmpty)

        let payload = FakePayload(json: ["k": 1])
        let a = try writer.write(payload, kind: .metric, date: Date(timeIntervalSince1970: 0))
        let b = try writer.write(payload, kind: .metric, date: Date(timeIntervalSince1970: 86400))
        let d = try writer.write(payload, kind: .diagnostic, date: Date(timeIntervalSince1970: 0))

        #expect(try writer.files(kind: .metric).map(\.lastPathComponent) == [a, b].map(\.lastPathComponent))
        #expect(try writer.files(kind: .diagnostic).map(\.lastPathComponent) == [d.lastPathComponent])
        #expect(try writer.files().count == 3)
    }

    @Test func defaultDirectoryIsLibraryPerf() {
        #expect(PayloadWriter.defaultDirectory.lastPathComponent == "Perf")
        #expect(PayloadWriter.defaultDirectory.deletingLastPathComponent().lastPathComponent == "Library")
    }
}
