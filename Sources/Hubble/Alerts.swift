import Foundation

struct DiskAlert: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case freeSpaceBelow, usageAbove, growth, sizeAbove
        var id: String { rawValue }

        var label: String {
            switch self {
            case .freeSpaceBelow: "Free space falls below"
            case .usageAbove: "Disk usage rises above"
            case .growth: "Something grows by more than"
            case .sizeAbove: "Something becomes larger than"
            }
        }

        /// Disk alerts are checked continuously; the others after each scan.
        var needsScan: Bool { self == .growth || self == .sizeAbove }
    }

    enum Scope: Codable, Hashable {
        /// Any single growth spot found by the scan.
        case anything
        /// Everything scanned.
        case total
        case folder(String)
        /// All folders matched by a cleanup rule.
        case rule(UUID)
    }

    enum Window: Double, Codable, CaseIterable, Identifiable {
        case sinceLastScan = 0, day = 86400, week = 604800, month = 2_592_000
        var id: Double { rawValue }

        var label: String {
            switch self {
            case .sinceLastScan: "since the last scan"
            case .day: "within a day"
            case .week: "within a week"
            case .month: "within a month"
            }
        }
    }

    var id = UUID()
    var enabled = true
    var kind: Kind
    var scope: Scope = .total
    var bytes: Int64 = 10 << 30
    var percent: Double = 90
    var window: Window = .sinceLastScan

    static let defaults: [DiskAlert] = [
        DiskAlert(kind: .freeSpaceBelow, bytes: 20 << 30),
        DiskAlert(kind: .growth, scope: .anything, bytes: 5 << 30),
        DiskAlert(kind: .growth, scope: .total, bytes: 25 << 30, window: .week),
    ]
}

struct AlertState: Codable, Equatable {
    struct Sample: Codable, Equatable {
        let date: Date
        let value: Int64
    }

    var samples: [Sample] = []
    /// The scan root the samples belong to; samples are reset when it changes.
    var sampleRoot: String?
    var triggered = false
    var lastFired: Date?
    var lastValue: Int64?
}

struct AlertEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let alertID: UUID
    let title: String
    let body: String
    var path: String?
}

struct DiskReading {
    let free: Int64
    let total: Int64
}

struct ScanReading {
    let date: Date
    let root: String
    let total: Int64
    let topGrowth: GrowthItem?
    /// Size of a folder in the scan, nil when it isn't inside the scanned folder.
    let folderSize: (String) -> Int64?
    let ruleTotal: (UUID) -> Int64
    let ruleName: (UUID) -> String
}

enum AlertEvaluator {
    static let sampleRetention: TimeInterval = 35 * 86400

    // MARK: Continuous disk checks

    static func evaluate(_ alert: DiskAlert, state: inout AlertState, disk: DiskReading, now: Date) -> AlertEvent? {
        let used = disk.total - disk.free
        let usedPercent = Double(used) / Double(max(disk.total, 1)) * 100
        let condition: Bool
        let rearm: Bool
        switch alert.kind {
        case .freeSpaceBelow:
            state.lastValue = disk.free
            condition = disk.free < alert.bytes
            rearm = disk.free > alert.bytes + max(1 << 30, alert.bytes / 20)
        case .usageAbove:
            state.lastValue = used
            condition = usedPercent > alert.percent
            rearm = usedPercent < alert.percent - 1
        case .growth, .sizeAbove:
            return nil
        }
        guard sticky(condition: condition, rearm: rearm, state: &state, now: now) else { return nil }
        if alert.kind == .freeSpaceBelow {
            return AlertEvent(date: now, alertID: alert.id, title: "Low disk space",
                              body: "Only \(disk.free.bytes) free (your alert is set below \(alert.bytes.bytes)).")
        }
        return AlertEvent(date: now, alertID: alert.id, title: "Disk is \(Int(usedPercent))% full",
                          body: "\(disk.free.bytes) free of \(disk.total.bytes).")
    }

    // MARK: After a scan

    static func evaluate(_ alert: DiskAlert, state: inout AlertState, scan: ScanReading) -> AlertEvent? {
        guard alert.kind.needsScan else { return nil }

        if alert.scope == .anything {
            guard alert.kind == .growth, let top = scan.topGrowth else { return nil }
            state.lastValue = top.delta
            guard top.delta >= alert.bytes else { return nil }
            state.lastFired = scan.date
            return AlertEvent(date: scan.date, alertID: alert.id,
                              title: "\(top.name) grew by \(top.delta.bytes)",
                              body: "\(abbreviatePath(top.path)) is now \(top.size.bytes).", path: top.path)
        }

        if state.sampleRoot != scan.root {
            state = AlertState(sampleRoot: scan.root)
        }
        guard let value = measure(alert.scope, scan) else {
            state.lastValue = nil
            return nil
        }
        let previous = state.samples
        state.samples.append(.init(date: scan.date, value: value))
        let cutoff = scan.date.addingTimeInterval(-sampleRetention)
        if state.samples.count > 2 { state.samples.removeAll { $0.date < cutoff } }
        let name = scopeName(alert.scope, scan.ruleName)

        switch alert.kind {
        case .sizeAbove:
            state.lastValue = value
            let fire = sticky(condition: value >= alert.bytes, rearm: value < alert.bytes - alert.bytes / 20,
                              state: &state, now: scan.date)
            guard fire else { return nil }
            return AlertEvent(date: scan.date, alertID: alert.id, title: "\(name) is now \(value.bytes)",
                              body: "It went above your \(alert.bytes.bytes) alert.", path: path(alert.scope))
        case .growth:
            guard let baseline = baseline(previous, window: alert.window, now: scan.date) else {
                state.lastValue = nil
                return nil
            }
            let delta = value - baseline
            state.lastValue = delta
            let condition = delta >= alert.bytes
            let fire: Bool
            if alert.window == .sinceLastScan {
                fire = condition
                if fire { state.lastFired = scan.date }
            } else {
                fire = sticky(condition: condition, rearm: !condition, state: &state, now: scan.date)
            }
            guard fire else { return nil }
            var body = "\(name) is now \(value.bytes)."
            if let top = scan.topGrowth, alert.scope == .total {
                body += " Biggest addition: \(top.name) (+\(top.delta.bytes))."
            }
            return AlertEvent(date: scan.date, alertID: alert.id,
                              title: "\(name) grew by \(delta.bytes) \(alert.window.label)",
                              body: body, path: path(alert.scope))
        default:
            return nil
        }
    }

    /// The most recent sample at least `window` old, or the oldest one if none is that old yet
    /// (growth over a shorter span is a lower bound for growth over the full window).
    static func baseline(_ samples: [AlertState.Sample], window: DiskAlert.Window, now: Date) -> Int64? {
        guard !samples.isEmpty else { return nil }
        if window == .sinceLastScan { return samples.last?.value }
        let cutoff = now.addingTimeInterval(-window.rawValue)
        return (samples.last { $0.date <= cutoff } ?? samples.first)?.value
    }

    private static func measure(_ scope: DiskAlert.Scope, _ scan: ScanReading) -> Int64? {
        switch scope {
        case .anything: nil
        case .total: scan.total
        case .folder(let p): scan.folderSize(p)
        case .rule(let id): scan.ruleTotal(id)
        }
    }

    private static func path(_ scope: DiskAlert.Scope) -> String? {
        if case .folder(let p) = scope { return p }
        return nil
    }

    static func scopeName(_ scope: DiskAlert.Scope, _ ruleName: (UUID) -> String) -> String {
        switch scope {
        case .anything: "Any folder or file"
        case .total: "Disk usage"
        case .folder(let p): (p as NSString).lastPathComponent
        case .rule(let id): ruleName(id)
        }
    }

    /// Fires once when the condition becomes true; re-arms only once `rearm` holds.
    private static func sticky(condition: Bool, rearm: Bool, state: inout AlertState, now: Date) -> Bool {
        if condition && !state.triggered {
            state.triggered = true
            state.lastFired = now
            return true
        }
        if !condition && rearm { state.triggered = false }
        return false
    }

    private static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension DiskAlert {
    func summary(ruleName: (UUID) -> String) -> String {
        switch kind {
        case .freeSpaceBelow:
            return "Free space falls below \(bytes.bytes)"
        case .usageAbove:
            return "Disk is more than \(Int(percent))% full"
        case .growth:
            return "\(AlertEvaluator.scopeName(scope, ruleName)) grows by more than \(bytes.bytes) \(scope == .anything ? DiskAlert.Window.sinceLastScan.label : window.label)"
        case .sizeAbove:
            return "\(AlertEvaluator.scopeName(scope, ruleName)) becomes larger than \(bytes.bytes)"
        }
    }

    var icon: String {
        switch kind {
        case .freeSpaceBelow: "externaldrive.badge.exclamationmark"
        case .usageAbove: "gauge.with.dots.needle.100percent"
        case .growth: "chart.line.uptrend.xyaxis"
        case .sizeAbove: "arrow.up.left.and.arrow.down.right"
        }
    }
}
