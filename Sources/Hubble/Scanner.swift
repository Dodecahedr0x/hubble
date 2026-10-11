import Foundation

final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var current = ""
    private var cancelled = false

    func add(files f: Int, bytes b: Int64, current c: String) {
        lock.lock(); files += f; bytes += b; current = c; lock.unlock()
    }

    func read() -> (files: Int, bytes: Int64, current: String) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes, current)
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Scans a directory tree with a fixed pool of worker threads pulling directories from a shared
/// LIFO stack (depth-first keeps the number of pending directories, and memory, small).
final class DiskScanner: @unchecked Sendable {
    static let keepThreshold: Int64 = 1 << 20          // 1 MB: smaller items are aggregated
    static let topFileThreshold: Int64 = 10 << 20      // 10 MB: candidates for "Largest files"
    static let topFileLimit = 500
    /// Measured on APFS: throughput peaks around 8 threads, beyond that kernel contention dominates.
    static let defaultThreadCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

    /// Cloud-synced folders (File Provider): their files are often online-only, and reading them
    /// can block indefinitely while the provider tries to download them. Keyed by parent folder.
    static let alwaysSkipped: [String: Set<String>] = [
        NSHomeDirectory() + "/Library": ["CloudStorage", "Mobile Documents"],
    ]
    /// Directories flagged "dataless" by the File Provider live in the cloud, not on disk.
    private static let datalessFlag: UInt32 = 0x40000000 // SF_DATALESS
    private static let progressInterval = 64           // directories between progress updates

    /// One directory to scan. A job finalizes once it and all its child jobs are done.
    private final class Job {
        let node: FileNode
        let path: String
        let insideMatch: Bool
        let parent: Job?
        var subdirs: [FileNode] = []
        var remaining = 1

        init(node: FileNode, path: String, insideMatch: Bool, parent: Job?) {
            self.node = node
            self.path = path
            self.insideMatch = insideMatch
            self.parent = parent
        }
    }

    /// Per-thread state, merged once the scan ends, so the hot path takes no shared locks.
    private final class Worker {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: DiskScanner.bufferSize, alignment: 16)
        var files = 0
        var unreadable = 0
        var topFiles: [FileNode] = []
        var matches: [FileNode] = []
        var pendingFiles = 0
        var pendingBytes: Int64 = 0
        var pendingDirs = 0

        deinit { buffer.deallocate() }
    }

    private let matcher: RuleMatcher
    private let progress: ScanProgress
    private let threadCount: Int
    private let qos: QualityOfService
    private var rootDev: dev_t = 0

    private let stackLock = NSCondition()
    private var stack: [Job] = []
    private var idle = 0
    private var finished = false
    private let done = DispatchSemaphore(value: 0)
    private let countLock = NSLock()

    init(rules: [Rule], progress: ScanProgress = ScanProgress(),
         threads: Int = DiskScanner.defaultThreadCount, qos: QualityOfService = .userInitiated) {
        matcher = RuleMatcher(rules: rules)
        self.progress = progress
        threadCount = max(1, threads)
        self.qos = qos
    }

    func scan(root: String) -> ScanResult {
        let start = Date()
        let rootNode = FileNode(name: (root as NSString).lastPathComponent, isDirectory: true)
        rootNode.rootPath = root
        var workers: [Worker] = []
        var st = stat()
        if lstat(root, &st) == 0 {
            rootDev = st.st_dev
            rootNode.modified = Date(timespec: st.st_mtimespec)
            stack.append(Job(node: rootNode, path: root, insideMatch: false, parent: nil))
            workers = (0..<threadCount).map { _ in Worker() }
            for w in workers {
                let t = Thread { [self] in run(w) }
                t.qualityOfService = qos
                t.name = "Hubble scanner"
                t.start()
            }
            done.wait()
        }
        let top = workers.flatMap(\.topFiles).sorted { $0.size > $1.size }.prefix(Self.topFileLimit)
        return ScanResult(root: rootNode,
                          matches: workers.flatMap(\.matches).sorted { $0.size > $1.size },
                          topFiles: Array(top),
                          fileCount: workers.reduce(0) { $0 + $1.files },
                          unreadable: workers.isEmpty ? 1 : workers.reduce(0) { $0 + $1.unreadable },
                          duration: Date().timeIntervalSince(start),
                          date: Date())
    }

    // MARK: Work stack

    private func run(_ worker: Worker) {
        while let job = pop() {
            process(job, worker)
        }
        flushProgress(worker, path: "")
    }

    private func pop() -> Job? {
        stackLock.lock()
        defer { stackLock.unlock() }
        while stack.isEmpty && !finished {
            idle += 1
            stackLock.wait()
            idle -= 1
        }
        return finished ? nil : stack.popLast()
    }

    private func push(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        stackLock.lock()
        stack.append(contentsOf: jobs)
        for _ in 0..<min(idle, jobs.count) { stackLock.signal() }
        stackLock.unlock()
    }

    private func finish() {
        stackLock.lock()
        finished = true
        stackLock.broadcast()
        stackLock.unlock()
        done.signal()
    }

    // MARK: Directory processing

    private func process(_ job: Job, _ worker: Worker) {
        defer { complete(job, worker) }
        if progress.isCancelled { return }
        let node = job.node
        let path = job.path
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            worker.unreadable += 1
            return
        }
        let skipped = Self.alwaysSkipped[path]
        let checkSiblings = matcher.usesSiblings && !job.insideMatch
        var siblingMask: UInt64 = 0
        var subdirs: [(name: String, mtime: timespec)] = []
        var files = 0
        var bytes: Int64 = 0
        var otherSize: Int64 = 0
        var otherCount = 0

        Self.readEntries(fd: fd, buffer: worker.buffer) { e in
            if checkSiblings { siblingMask |= matcher.siblingMask(e.namePointer) }
            if e.isDirectory {
                if e.device == rootDev && e.flags & Self.datalessFlag == 0 {
                    let name = e.name
                    if skipped?.contains(name) != true { subdirs.append((name, e.modified)) }
                }
                return
            }
            files += 1
            bytes += e.allocated
            if e.isRegular && e.allocated >= Self.keepThreshold {
                let f = FileNode(name: e.name, isDirectory: false, size: e.allocated, modified: Date(timespec: e.modified))
                f.parent = node
                node.children.append(f)
                if e.allocated >= Self.topFileThreshold { worker.topFiles.append(f) }
            } else {
                otherSize += e.allocated
                otherCount += 1
            }
        }
        close(fd)

        node.size = bytes
        node.otherSize = otherSize
        node.otherCount = otherCount
        worker.files += files
        worker.pendingFiles += files
        worker.pendingBytes += bytes
        worker.pendingDirs += 1
        if worker.pendingDirs >= Self.progressInterval { flushProgress(worker, path: path) }

        var children: [Job] = []
        children.reserveCapacity(subdirs.count)
        for sub in subdirs {
            let full = FileNode.join(path, sub.name)
            let rule = matcher.isEmpty ? nil
                : matcher.match(name: sub.name, path: full, siblingMask: siblingMask, allowPrioritize: !job.insideMatch)
            if rule?.action == .ignore { continue }
            let child = FileNode(name: sub.name, isDirectory: true, modified: Date(timespec: sub.mtime))
            child.ruleID = rule?.id
            children.append(Job(node: child, path: full, insideMatch: job.insideMatch || rule != nil, parent: job))
        }
        if !children.isEmpty {
            job.subdirs = children.map(\.node)
            countLock.lock(); job.remaining += children.count; countLock.unlock()
            push(children)
        }
    }

    private func flushProgress(_ worker: Worker, path: String) {
        progress.add(files: worker.pendingFiles, bytes: worker.pendingBytes, current: path)
        worker.pendingFiles = 0
        worker.pendingBytes = 0
        worker.pendingDirs = 0
    }

    private func complete(_ job: Job, _ worker: Worker) {
        var job = job
        while true {
            countLock.lock()
            job.remaining -= 1
            let isDone = job.remaining == 0
            countLock.unlock()
            guard isDone else { return }
            finalize(job, worker)
            guard let parent = job.parent else {
                finish()
                return
            }
            job = parent
        }
    }

    /// Runs after every subdirectory is done: rolls up sizes and prunes small children.
    private func finalize(_ job: Job, _ worker: Worker) {
        let node = job.node
        for child in job.subdirs {
            node.size += child.size
            if child.size >= Self.keepThreshold {
                child.parent = node
                node.children.append(child)
                if child.ruleID != nil { worker.matches.append(child) }
            } else {
                node.otherSize += child.size
                node.otherCount += 1
            }
        }
        job.subdirs = []
        node.children.sort { $0.size > $1.size }
    }
}

// MARK: - getattrlistbulk

extension DiskScanner {
    struct Entry {
        let namePointer: UnsafePointer<CChar>
        let nameLength: Int
        let isDirectory: Bool
        let isRegular: Bool
        let device: dev_t
        let flags: UInt32
        let modified: timespec
        let allocated: Int64

        var name: String {
            namePointer.withMemoryRebound(to: UInt8.self, capacity: nameLength) {
                String(decoding: UnsafeBufferPointer(start: $0, count: nameLength), as: UTF8.self)
            }
        }
    }

    static let bufferSize = 256 * 1024

    private static let attributes: attrlist = {
        var a = attrlist()
        a.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        // RETURNED_ATTRS | NAME | DEVID | OBJTYPE | MODTIME | FLAGS
        a.commonattr = 0x8000_0000 | 0x1 | 0x2 | 0x8 | 0x400 | 0x4_0000
        a.fileattr = 0x4 // ATTR_FILE_ALLOCSIZE
        return a
    }()

    private static let directoryType = fsobj_type_t(VDIR.rawValue)
    private static let regularType = fsobj_type_t(VREG.rawValue)

    /// Reads every entry of an open directory in batches: one syscall returns many entries
    /// with their attributes, instead of a readdir + stat per entry.
    static func readEntries(fd: Int32, buffer: UnsafeMutableRawPointer, _ body: (Entry) -> Void) {
        var attrs = attributes
        let packInvalid: UInt64 = 0x8 // FSOPT_PACK_INVAL_ATTRS: keeps the record layout fixed
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, packInvalid)
            if count <= 0 { return }
            var record = buffer
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                var p = record + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                let nameRef = p.loadUnaligned(as: attrreference_t.self)
                let namePointer = UnsafePointer((p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                p += MemoryLayout<attrreference_t>.size
                let device = p.loadUnaligned(as: dev_t.self)
                p += MemoryLayout<dev_t>.size
                let type = p.loadUnaligned(as: fsobj_type_t.self)
                p += MemoryLayout<fsobj_type_t>.size
                let mtime = p.loadUnaligned(as: timespec.self)
                p += MemoryLayout<timespec>.size
                let flags = p.loadUnaligned(as: UInt32.self)
                p += MemoryLayout<UInt32>.size
                let allocated = returned.fileattr & 0x4 != 0 ? p.loadUnaligned(as: off_t.self) : 0
                body(Entry(namePointer: namePointer,
                           nameLength: max(0, Int(nameRef.attr_length) - 1),
                           isDirectory: type == directoryType,
                           isRegular: type == regularType,
                           device: device,
                           flags: flags,
                           modified: mtime,
                           allocated: Int64(allocated)))
                record += length
            }
        }
    }
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}
