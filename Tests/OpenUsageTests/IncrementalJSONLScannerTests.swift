import Foundation
import XCTest
@testable import OpenUsage

final class IncrementalJSONLScannerTests: XCTestCase {
    func testLimitsConcurrentParsesAndKeepsFileOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let files = try (0..<20).map { index in
            let url = directory.appendingPathComponent(String(format: "%02d.jsonl", index))
            let data = Data("\(index)".utf8)
            try data.write(to: url)
            return JSONLScanning.DiscoveredFile(path: url.path, size: data.count, mtime: now)
        }
        let probe = ConcurrencyProbe()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 3)

        let items = await scanner.items(from: files, since: now.addingTimeInterval(-1)) { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.01)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        XCTAssertEqual(items, Array(0..<20))
        XCTAssertLessThanOrEqual(probe.maximumActive, 3)
    }
}

private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int {
        lock.withLock { maximum }
    }

    func begin() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func end() {
        lock.withLock {
            active -= 1
        }
    }
}
