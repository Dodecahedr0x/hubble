import Foundation

/// Persistence in ~/Library/Application Support/Hubble.
enum Store {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Hubble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        return dir
    }()

    private static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func snapshotURL(root: String) -> URL {
        let safe = root.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("snapshots/\(safe).tsv")
    }

    // MARK: JSON values

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // MARK: Snapshots (size \t path per line)

    static func loadSnapshot(root: String) -> [String: Int64]? {
        guard let text = try? String(contentsOf: snapshotURL(root: root), encoding: .utf8) else { return nil }
        var map: [String: Int64] = [:]
        map.reserveCapacity(text.count / 80)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t"), let size = Int64(line[..<tab]) else { continue }
            map[String(line[line.index(after: tab)...])] = size
        }
        return map
    }

    static func saveSnapshot(_ root: FileNode) {
        var out = ""
        func walk(_ n: FileNode, _ path: String) {
            if n.name.contains("\n") { return }
            out += "\(n.size)\t\(path)\n"
            for c in n.children { walk(c, FileNode.join(path, c.name)) }
        }
        walk(root, root.path)
        try? out.write(to: snapshotURL(root: root.path), atomically: true, encoding: .utf8)
    }
}
