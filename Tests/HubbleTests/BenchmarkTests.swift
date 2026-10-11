import XCTest
@testable import Hubble

/// Real-disk smoke test. Run with: HUBBLE_BENCH=~/some/folder swift test --filter Benchmark
final class BenchmarkTests: XCTestCase {
    func testScanRealFolder() throws {
        guard let root = ProcessInfo.processInfo.environment["HUBBLE_BENCH"] else { throw XCTSkip("HUBBLE_BENCH not set") }
        let threads = ProcessInfo.processInfo.environment["HUBBLE_THREADS"].flatMap(Int.init) ?? DiskScanner.defaultThreadCount
        let r = DiskScanner(rules: Rule.defaults, threads: threads).scan(root: root)
        print("threads \(threads): scanned \(r.root.size.bytes), \(r.fileCount) files in \(String(format: "%.1f", r.duration))s, unreadable \(r.unreadable)")
        for m in r.matches.prefix(8) { print("  match \(m.size.bytes)\t\(m.path)") }
        for c in r.root.children.prefix(5) { print("  top \(c.size.bytes)\t\(c.name)") }
    }
}

extension BenchmarkTests {
    /// Measures snapshot persistence and the growth diff on a real folder.
    func testSnapshotAndGrowthOnRealFolder() throws {
        guard let root = ProcessInfo.processInfo.environment["HUBBLE_BENCH"] else { throw XCTSkip("HUBBLE_BENCH not set") }
        let r = DiskScanner(rules: Rule.defaults).scan(root: root)
        var t = Date()
        let url = Store.snapshotURL(root: root)
        let backup = try? Data(contentsOf: url)
        defer { if let backup { try? backup.write(to: url) } else { try? FileManager.default.removeItem(at: url) } }
        Store.saveSnapshot(r.root)
        let saveTime = Date().timeIntervalSince(t); t = Date()
        let snap = try XCTUnwrap(Store.loadSnapshot(root: root))
        let loadTime = Date().timeIntervalSince(t); t = Date()
        let items = Growth.compute(root: r.root, previous: snap, minDelta: 1 << 20)
        print(String(format: "snapshot %d entries, %lld bytes: save %.2fs load %.2fs diff %.2fs",
                     snap.count, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0,
                     saveTime, loadTime, Date().timeIntervalSince(t)))
        XCTAssertTrue(items.isEmpty)
    }
}
