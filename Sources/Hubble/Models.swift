import Foundation

/// A node of the scanned tree. Only items >= `DiskScanner.keepThreshold` are kept as nodes;
/// smaller ones are folded into their parent's `otherSize`.
final class FileNode: Identifiable, @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    var size: Int64
    var modified: Date?
    var children: [FileNode] = []
    var otherSize: Int64 = 0
    var otherCount = 0
    weak var parent: FileNode?
    var ruleID: UUID?
    /// Set on the root only.
    var rootPath: String?

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        return FileNode.join(parent.path, name)
    }

    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    func isDescendant(of other: FileNode) -> Bool {
        var p = parent
        while let n = p {
            if n === other { return true }
            p = n.parent
        }
        return false
    }

    /// Removes the node from the tree and subtracts its size from all ancestors.
    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var p: FileNode? = parent
        while let n = p {
            n.size -= size
            p = n.parent
        }
        self.parent = nil
    }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case prioritize, ignore
    var id: String { rawValue }
    var label: String { self == .prioritize ? "Cleanup candidate" : "Ignore" }
}

struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// A folder-name glob (`node_modules`, `*.xcarchive`) or, if it contains `/`, a path glob (`~/Library/Caches`).
    var pattern: String
    /// Optional glob that must match a sibling entry (e.g. `Cargo.toml` next to `target`).
    var requiresSibling: String = ""
    var action: RuleAction = .prioritize
    var enabled = true

    static let defaults: [Rule] = [
        Rule(name: "Rust build output", pattern: "target", requiresSibling: "Cargo.toml"),
        Rule(name: "Node modules", pattern: "node_modules"),
        Rule(name: "Swift build", pattern: ".build", requiresSibling: "Package.swift"),
        Rule(name: "Next.js build", pattern: ".next", requiresSibling: "package.json"),
        Rule(name: "Python virtualenv", pattern: ".venv"),
        Rule(name: "Xcode DerivedData", pattern: "~/Library/Developer/Xcode/DerivedData"),
        Rule(name: "Xcode Archives", pattern: "~/Library/Developer/Xcode/Archives"),
        Rule(name: "iOS Device Support", pattern: "~/Library/Developer/Xcode/iOS DeviceSupport"),
        Rule(name: "Cargo registry", pattern: "~/.cargo/registry"),
        Rule(name: "Gradle caches", pattern: "~/.gradle/caches"),
        Rule(name: "npm cache", pattern: "~/.npm/_cacache"),
        Rule(name: "User cache", pattern: "~/.cache"),
        Rule(name: "App caches", pattern: "~/Library/Caches"),
    ]
}

struct RuleMatcher: Sendable {
    private struct Compiled: Sendable {
        let rule: Rule
        let pattern: [CChar]
        let isPath: Bool
        /// Set for path patterns without glob characters, which are compared directly.
        let literalPath: String?
        let siblingBit: UInt64?
    }

    private let compiled: [Compiled]
    private let siblingPatterns: [[CChar]]

    init(rules: [Rule], home: String = NSHomeDirectory()) {
        var siblings: [String] = []
        compiled = rules.filter(\.enabled).compactMap { rule in
            var p = rule.pattern.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            if p.hasPrefix("~") { p = home + p.dropFirst() }
            if p.count > 1, p.hasSuffix("/") { p.removeLast() }
            let isPath = p.contains("/")
            let isLiteral = !p.contains(where: { "*?[".contains($0) })
            var bit: UInt64?
            let sib = rule.requiresSibling.trimmingCharacters(in: .whitespaces)
            if !sib.isEmpty {
                let index = siblings.firstIndex(of: sib) ?? { siblings.append(sib); return siblings.count - 1 }()
                if index < 64 { bit = 1 << UInt64(index) }
            }
            return Compiled(rule: rule, pattern: p.utf8CString.map { $0 }, isPath: isPath,
                            literalPath: isPath && isLiteral ? p : nil, siblingBit: bit)
        }
        siblingPatterns = siblings.prefix(64).map { $0.utf8CString.map { $0 } }
    }

    var isEmpty: Bool { compiled.isEmpty }
    var usesSiblings: Bool { !siblingPatterns.isEmpty }

    /// Bit set of the sibling patterns that `name` satisfies.
    func siblingMask(_ name: UnsafePointer<CChar>) -> UInt64 {
        var mask: UInt64 = 0
        for (i, p) in siblingPatterns.enumerated() where fnmatch(p, name, 0) == 0 {
            mask |= 1 << UInt64(i)
        }
        return mask
    }

    /// Ignore rules always apply; prioritize rules only when `allowPrioritize` (i.e. not nested in another match).
    /// `siblingMask` is the union of `siblingMask(_:)` over the folder's siblings.
    func match(name: String, path: String, siblingMask: UInt64, allowPrioritize: Bool) -> Rule? {
        name.withCString { cName in
            var found: Rule?
            for c in compiled {
                if c.rule.action == .prioritize && (!allowPrioritize || found != nil) { continue }
                if let bit = c.siblingBit, siblingMask & bit == 0 { continue }
                if let literal = c.literalPath {
                    guard literal == path else { continue }
                } else if c.isPath {
                    guard fnmatch(c.pattern, path, 0) == 0 else { continue }
                } else {
                    guard fnmatch(c.pattern, cName, 0) == 0 else { continue }
                }
                if c.rule.action == .ignore { return c.rule }
                found = c.rule
            }
            return found
        }
    }

    func match(name: String, path: String, siblings: [String], allowPrioritize: Bool) -> Rule? {
        let mask = siblings.reduce(UInt64(0)) { m, s in s.withCString { m | siblingMask($0) } }
        return match(name: name, path: path, siblingMask: mask, allowPrioritize: allowPrioritize)
    }
}

struct GrowthItem: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let delta: Int64
    let size: Int64
    let isNew: Bool
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct GrowthReport: Codable {
    let date: Date
    let root: String
    let previousDate: Date?
    let totalDelta: Int64
    var items: [GrowthItem]
}

struct ScanRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let root: String
    let totalSize: Int64
    let fileCount: Int
    let duration: TimeInterval
}

struct ScanResult {
    let id = UUID()
    let root: FileNode
    var matches: [FileNode]
    var topFiles: [FileNode]
    let fileCount: Int
    let unreadable: Int
    let duration: TimeInterval
    let date: Date
}

enum Growth {
    /// Walks down from `root`, following children that explain most of a node's growth,
    /// and reports the deepest node where growth is concentrated.
    static func compute(root: FileNode, previous: [String: Int64], minDelta: Int64) -> [GrowthItem] {
        var out: [GrowthItem] = []
        func walk(_ n: FileNode, _ path: String) {
            let delta = n.size - (previous[path] ?? 0)
            guard delta >= minDelta else { return }
            if n.isDirectory {
                let floor = max(minDelta, delta / 5)
                var significant: [(FileNode, String)] = []
                var covered: Int64 = 0
                for c in n.children {
                    let cp = FileNode.join(path, c.name)
                    let cd = c.size - (previous[cp] ?? 0)
                    if cd >= floor {
                        significant.append((c, cp))
                        covered += cd
                    }
                }
                if !significant.isEmpty && covered * 10 >= delta * 7 {
                    for (c, cp) in significant { walk(c, cp) }
                    return
                }
            }
            out.append(GrowthItem(path: path, delta: delta, size: n.size,
                                  isNew: previous[path] == nil, isDirectory: n.isDirectory))
        }
        walk(root, root.path)
        return out.sorted { $0.delta > $1.delta }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
