import XCTest
@testable import Hubble

final class HubbleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hubble-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ rel: String, mb: Int) throws {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: mb << 20).write(to: url)
    }

    func testRuleMatcherSiblingAndPath() {
        let m = RuleMatcher(rules: [
            Rule(name: "rust", pattern: "target", requiresSibling: "Cargo.toml"),
            Rule(name: "caches", pattern: "~/Library/Caches"),
            Rule(name: "skip", pattern: "secret", action: .ignore),
        ], home: "/Users/x")
        XCTAssertEqual(m.match(name: "target", path: "/p/target", siblings: ["Cargo.toml", "src"], allowPrioritize: true)?.name, "rust")
        XCTAssertNil(m.match(name: "target", path: "/p/target", siblings: ["pom.xml"], allowPrioritize: true))
        XCTAssertEqual(m.match(name: "Caches", path: "/Users/x/Library/Caches", siblings: [], allowPrioritize: true)?.name, "caches")
        XCTAssertNil(m.match(name: "target", path: "/p/target", siblings: ["Cargo.toml"], allowPrioritize: false))
        XCTAssertEqual(m.match(name: "secret", path: "/p/secret", siblings: [], allowPrioritize: false)?.action, .ignore)
    }

    func testScanSizesMatchesAndIgnores() throws {
        try write("proj/Cargo.toml", mb: 0)
        try write("proj/target/debug/big.bin", mb: 3)
        try write("proj/target/debug/target/nested.bin", mb: 2) // nested match must not be reported
        try write("web/node_modules/x/a.bin", mb: 2)
        try write("skip/huge.bin", mb: 20)
        try write("movie.mov", mb: 12)

        let rules = [Rule(name: "rust", pattern: "target", requiresSibling: "Cargo.toml"),
                     Rule(name: "node", pattern: "node_modules"),
                     Rule(name: "skip", pattern: "skip", action: .ignore)]
        let r = DiskScanner(rules: rules).scan(root: tmp.path)

        XCTAssertEqual(Set(r.matches.map(\.name)), ["target", "node_modules"])
        XCTAssertEqual(r.topFiles.map(\.name), ["movie.mov"])
        XCTAssertNil(r.root.children.first { $0.name == "skip" })
        XCTAssertGreaterThanOrEqual(r.root.size, 19 << 20)
        XCTAssertLessThan(r.root.size, 25 << 20)
        XCTAssertEqual(r.root.children.first?.name, "movie.mov")
    }

    func testGrowthFindsDeepestConcentratedNode() throws {
        try write("a/b/c/old.bin", mb: 2)
        let before = DiskScanner(rules: []).scan(root: tmp.path)
        var previous: [String: Int64] = [:]
        func walk(_ n: FileNode, _ p: String) { previous[p] = n.size; n.children.forEach { walk($0, FileNode.join(p, $0.name)) } }
        walk(before.root, before.root.path)

        try write("a/b/c/new/fresh.bin", mb: 30)
        try write("a/noise.bin", mb: 1)
        let after = DiskScanner(rules: []).scan(root: tmp.path)
        let items = Growth.compute(root: after.root, previous: previous, minDelta: 10 << 20)

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].path.hasSuffix("a/b/c/new/fresh.bin"), items[0].path)
        XCTAssertTrue(items[0].isNew)
    }

    func testSnapshotRoundTrip() throws {
        try write("d/f.bin", mb: 2)
        let r = DiskScanner(rules: []).scan(root: tmp.path)
        Store.saveSnapshot(r.root)
        let snap = try XCTUnwrap(Store.loadSnapshot(root: tmp.path))
        XCTAssertEqual(snap[tmp.path], r.root.size)
        XCTAssertEqual(snap[tmp.path + "/d/f.bin"], 2 << 20)
        try? FileManager.default.removeItem(at: Store.snapshotURL(root: tmp.path))
    }

    func testParallelScanMatchesSingleThreaded() throws {
        for p in 0..<20 {
            try write("p\(p)/Cargo.toml", mb: 0)
            for d in 0..<5 { try write("p\(p)/target/d\(d)/x.bin", mb: 1 + (p + d) % 3) }
            try write("p\(p)/src/deep/er/still/file.bin", mb: 2)
        }
        let rules = [Rule(name: "rust", pattern: "target", requiresSibling: "Cargo.toml")]
        let one = DiskScanner(rules: rules, threads: 1).scan(root: tmp.path)
        let many = DiskScanner(rules: rules, threads: 8).scan(root: tmp.path)
        XCTAssertEqual(one.root.size, many.root.size)
        XCTAssertEqual(one.fileCount, many.fileCount)
        XCTAssertEqual(many.matches.count, 20)
        XCTAssertEqual(Set(one.matches.map(\.path)), Set(many.matches.map(\.path)))
        XCTAssertEqual(many.root.children.count, 20)
    }

    func testCancelledScanReturns() throws {
        for d in 0..<50 { try write("d\(d)/f.bin", mb: 1) }
        let progress = ScanProgress()
        progress.cancel()
        let r = DiskScanner(rules: [], progress: progress).scan(root: tmp.path)
        XCTAssertEqual(r.fileCount, 0)
    }
}
