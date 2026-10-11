import XCTest
@testable import Hubble

final class AlertTests: XCTestCase {
    private let gb: Int64 = 1 << 30
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func scan(_ total: Int64, at date: Date, root: String = "/r", folders: [String: Int64] = [:],
                      top: GrowthItem? = nil) -> ScanReading {
        ScanReading(date: date, root: root, total: total, topGrowth: top,
                    folderSize: { folders[$0] }, ruleTotal: { _ in 0 }, ruleName: { _ in "Rule" })
    }

    func testFreeSpaceFiresOnceAndRearmsWithMargin() {
        let alert = DiskAlert(kind: .freeSpaceBelow, bytes: 20 * gb)
        var s = AlertState()
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 30 * gb, total: 500 * gb), now: t0))
        XCTAssertNotNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 19 * gb, total: 500 * gb), now: t0))
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 18 * gb, total: 500 * gb), now: t0))
        // Just above the threshold is within the margin: still armed off.
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 20 * gb + 1, total: 500 * gb), now: t0))
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 19 * gb, total: 500 * gb), now: t0))
        // Well above re-arms, then dropping fires again.
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 40 * gb, total: 500 * gb), now: t0))
        XCTAssertNotNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 10 * gb, total: 500 * gb), now: t0))
    }

    func testUsagePercent() {
        let alert = DiskAlert(kind: .usageAbove, percent: 90)
        var s = AlertState()
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 60 * gb, total: 500 * gb), now: t0))
        let e = AlertEvaluator.evaluate(alert, state: &s, disk: DiskReading(free: 40 * gb, total: 500 * gb), now: t0)
        XCTAssertEqual(e?.title, "Disk is 92% full")
    }

    func testGrowthSinceLastScanFiresEveryTime() {
        let alert = DiskAlert(kind: .growth, scope: .total, bytes: 5 * gb)
        var s = AlertState()
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(100 * gb, at: t0)))
        XCTAssertNotNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(106 * gb, at: t0 + 3600)))
        XCTAssertNotNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(112 * gb, at: t0 + 7200)))
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(113 * gb, at: t0 + 9000)))
    }

    func testGrowthOverWeekUsesBaselineAndIsSticky() {
        let alert = DiskAlert(kind: .growth, scope: .total, bytes: 10 * gb, window: .week)
        var s = AlertState()
        let day: TimeInterval = 86400
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(100 * gb, at: t0)))
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(104 * gb, at: t0 + 2 * day)))
        // +11 GB vs the oldest sample within the week.
        XCTAssertNotNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(111 * gb, at: t0 + 4 * day)))
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(115 * gb, at: t0 + 5 * day)))
        // Ten days in, the baseline is the day-2 sample (104): +8 GB, condition clears and re-arms.
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(112 * gb, at: t0 + 10 * day)))
        XCTAssertFalse(s.triggered)
    }

    func testFolderSizeAboveAndRootChangeResets() {
        let alert = DiskAlert(kind: .sizeAbove, scope: .folder("/r/cache"), bytes: 20 * gb)
        var s = AlertState()
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(0, at: t0, folders: ["/r/cache": 10 * gb])))
        let e = AlertEvaluator.evaluate(alert, state: &s, scan: scan(0, at: t0 + 1, folders: ["/r/cache": 21 * gb]))
        XCTAssertEqual(e?.title, "cache is now \((21 * gb).bytes)")
        XCTAssertNil(AlertEvaluator.evaluate(alert, state: &s, scan: scan(0, at: t0 + 2, folders: ["/r/cache": 22 * gb])))
        _ = AlertEvaluator.evaluate(alert, state: &s, scan: scan(0, at: t0 + 3, root: "/other"))
        XCTAssertEqual(s.sampleRoot, "/other")
        XCTAssertFalse(s.triggered)
    }

    func testAnythingUsesTopGrowthSpot() {
        let alert = DiskAlert(kind: .growth, scope: .anything, bytes: 5 * gb)
        var s = AlertState()
        let top = GrowthItem(path: "/r/proj/target", delta: 7 * gb, size: 30 * gb, isNew: false, isDirectory: true)
        let e = AlertEvaluator.evaluate(alert, state: &s, scan: scan(0, at: t0, top: top))
        XCTAssertEqual(e?.title, "target grew by \((7 * gb).bytes)")
        XCTAssertEqual(e?.path, "/r/proj/target")
    }

    func testAlertsRoundTripThroughJSON() throws {
        let alerts = DiskAlert.defaults + [DiskAlert(kind: .sizeAbove, scope: .rule(UUID()), bytes: gb)]
        let data = try JSONEncoder().encode(alerts)
        XCTAssertEqual(try JSONDecoder().decode([DiskAlert].self, from: data), alerts)
    }
}
