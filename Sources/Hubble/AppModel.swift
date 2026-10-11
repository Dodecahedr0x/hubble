import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Live scan progress, kept apart from `AppModel` so frequent updates only redraw the views showing them.
@MainActor
final class ScanActivity: ObservableObject {
    @Published fileprivate(set) var files = 0
    @Published fileprivate(set) var bytes: Int64 = 0
    @Published fileprivate(set) var path = ""
}

enum ScanOrigin { case manual, automatic }

enum AutoScanInterval: TimeInterval, CaseIterable, Identifiable {
    case off = 0
    case hourly = 3600
    case sixHours = 21600
    case daily = 86400
    case weekly = 604800
    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .hourly: "Every hour"
        case .sixHours: "Every 6 hours"
        case .daily: "Every day"
        case .weekly: "Every week"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let diskRoot = "/System/Volumes/Data"
    static let shared = AppModel()

    @Published var rules: [Rule] { didSet { Store.save(rules, to: "rules.json") } }
    @Published var rootPath: String { didSet { UserDefaults.standard.set(rootPath, forKey: "rootPath") } }
    @Published var growthThreshold: Int64 {
        didSet {
            UserDefaults.standard.set(growthThreshold, forKey: "growthThreshold")
            recomputeGrowth()
        }
    }

    @Published var autoScan: AutoScanInterval {
        didSet {
            UserDefaults.standard.set(autoScan.rawValue, forKey: "autoScan")
            scheduleAutomaticScans()
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            if notificationsEnabled { requestNotificationPermission() }
        }
    }
    @Published var alerts: [DiskAlert] {
        didSet {
            Store.save(alerts, to: "alerts.json")
            alertStates = alertStates.filter { id, _ in alerts.contains { $0.id == id } }
            checkDiskAlerts()
        }
    }
    @Published private(set) var alertStates: [UUID: AlertState]
    @Published private(set) var alertEvents: [AlertEvent]
    @Published var alertsSeen: Date { didSet { UserDefaults.standard.set(alertsSeen, forKey: "alertsSeen") } }
    @Published var showInMenuBar: Bool { didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") } }

    @Published private(set) var isScanning = false
    @Published private(set) var scanOrigin: ScanOrigin = .manual
    let activity = ScanActivity()
    /// Set when a notification is clicked; the main window switches to this pane.
    @Published var requestedPane: Pane?
    /// Provided by a SwiftUI view (via `openWindow`), so non-view code can reopen the main window.
    var openMainWindow: (() -> Void)?

    @Published private(set) var result: ScanResult?
    @Published private(set) var report: GrowthReport?
    @Published private(set) var history: [ScanRecord]
    @Published var pendingTrash: [FileNode] = []
    @Published var errorMessage: String?

    private var previousSnapshot: [String: Int64]?
    private var previousDate: Date?
    private var scanProgress: ScanProgress?
    private var timer: Timer?
    private var scheduler: NSBackgroundActivityScheduler?
    private var scanCompletion: (() -> Void)?
    private var diskTimer: Timer?

    private init() {
        rules = Store.load([Rule].self, from: "rules.json") ?? Rule.defaults
        rootPath = UserDefaults.standard.string(forKey: "rootPath") ?? NSHomeDirectory()
        let t = UserDefaults.standard.object(forKey: "growthThreshold") as? Int64
        growthThreshold = t ?? 50 << 20
        history = Store.load([ScanRecord].self, from: "history.json") ?? []
        report = Store.load(GrowthReport.self, from: "last-report.json")
        let defaults = UserDefaults.standard
        autoScan = (defaults.object(forKey: "autoScan") as? Double).flatMap(AutoScanInterval.init) ?? .daily
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        alerts = Store.load([DiskAlert].self, from: "alerts.json") ?? DiskAlert.defaults
        alertStates = Store.load([UUID: AlertState].self, from: "alert-state.json") ?? [:]
        alertEvents = Store.load([AlertEvent].self, from: "alert-events.json") ?? []
        alertsSeen = defaults.object(forKey: "alertsSeen") as? Date ?? .distantPast
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        scheduleAutomaticScans()
        if notificationsEnabled { requestNotificationPermission() }
        startDiskMonitor()
    }

    var rootDisplayName: String {
        switch rootPath {
        case NSHomeDirectory(): return "Home folder"
        case Self.diskRoot: return "Entire disk"
        default: return (rootPath as NSString).lastPathComponent
        }
    }

    var lastScan: ScanRecord? { history.last }

    func rule(for id: UUID?) -> Rule? {
        guard let id else { return nil }
        return rules.first { $0.id == id }
    }

    // MARK: Scanning

    /// Automatic scans run at low priority with fewer threads so they stay out of the way.
    func startScan(origin: ScanOrigin = .manual, completion: (() -> Void)? = nil) {
        guard !isScanning else {
            completion?()
            return
        }
        isScanning = true
        scanOrigin = origin
        scanCompletion = completion
        activity.files = 0
        activity.bytes = 0
        activity.path = rootPath
        let progress = ScanProgress()
        scanProgress = progress
        let rules = rules
        let root = rootPath
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollProgress() }
        }
        // The scanner blocks while it waits for its workers, so keep it off Swift's cooperative pool.
        let automatic = origin == .automatic
        DispatchQueue.global(qos: automatic ? .utility : .userInitiated).async { [weak self] in
            let scanner = automatic
                ? DiskScanner(rules: rules, progress: progress, threads: 4, qos: .utility)
                : DiskScanner(rules: rules, progress: progress)
            let result = scanner.scan(root: root)
            if progress.isCancelled {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishCancelled() } }
                return
            }
            let previous = Store.loadSnapshot(root: root)
            Store.saveSnapshot(result.root)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(result, previous: previous) } }
        }
    }

    func cancelScan() { scanProgress?.cancel() }

    private func pollProgress() {
        guard let p = scanProgress?.read() else { return }
        activity.files = p.files
        activity.bytes = p.bytes
        if !p.current.isEmpty { activity.path = p.current }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        scanProgress = nil
        isScanning = false
        scanCompletion?()
        scanCompletion = nil
    }

    private func finishCancelled() { stopTimer() }

    private func finish(_ result: ScanResult, previous: [String: Int64]?) {
        defer { stopTimer() }
        previousDate = history.last { $0.root == result.root.path }?.date
        previousSnapshot = previous
        self.result = result
        history.append(ScanRecord(date: result.date, root: result.root.path, totalSize: result.root.size,
                                  fileCount: result.fileCount, duration: result.duration))
        if history.count > 200 { history.removeFirst(history.count - 200) }
        Store.save(history, to: "history.json")
        recomputeGrowth()
        checkScanAlerts(result)
        checkDiskAlerts()
    }

    private func recomputeGrowth() {
        guard let result, let previousSnapshot else {
            if result != nil { report = nil }
            return
        }
        let root = result.root
        let items = Growth.compute(root: root, previous: previousSnapshot, minDelta: growthThreshold)
        report = GrowthReport(date: result.date, root: root.path, previousDate: previousDate,
                              totalDelta: root.size - (previousSnapshot[root.path] ?? 0), items: items)
        Store.save(report, to: "last-report.json")
    }

    // MARK: Lookup & actions

    func node(at path: String) -> FileNode? {
        guard let root = result?.root else { return nil }
        if path == root.path { return root }
        guard path.hasPrefix(root.path) else { return nil }
        var node = root
        for comp in path.dropFirst(root.path.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    func requestTrash(_ nodes: [FileNode]) { pendingTrash = nodes }

    func requestTrash(path: String) {
        if let n = node(at: path) { pendingTrash = [n] }
    }

    func confirmTrash() {
        let nodes = pendingTrash
        pendingTrash = []
        var failed: [String] = []
        for n in nodes {
            let path = n.path
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                result?.matches.removeAll { $0 === n || $0.isDescendant(of: n) }
                result?.topFiles.removeAll { $0 === n || $0.isDescendant(of: n) }
                report?.items.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
                n.detach()
            } catch {
                failed.append("\(n.name): \(error.localizedDescription)")
            }
        }
        if !failed.isEmpty { errorMessage = failed.joined(separator: "\n") }
        objectWillChange.send()
        checkDiskAlerts()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { rootPath = url.path }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func volumeCapacity() -> (total: Int64, free: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: rootPath).resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (Int64(total), free)
    }
}

// MARK: - Background scanning

extension AppModel {
    var nextAutomaticScan: Date? {
        guard autoScan != .off else { return nil }
        return (lastScan?.date ?? Date()).addingTimeInterval(autoScan.rawValue)
    }

    /// Uses NSBackgroundActivityScheduler, which lets macOS pick a good moment
    /// (on power, not thermally constrained, user idle) within the tolerance window.
    func scheduleAutomaticScans() {
        scheduler?.invalidate()
        scheduler = nil
        guard autoScan != .off else { return }
        let s = NSBackgroundActivityScheduler(identifier: "app.hubble.diskscope.autoscan")
        s.repeats = true
        s.interval = autoScan.rawValue
        s.tolerance = autoScan.rawValue / 4
        s.qualityOfService = .utility
        s.schedule { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppModel.shared.startScan(origin: .automatic) { completion(.finished) }
                }
            }
        }
        scheduler = s

        // The scheduler waits a full interval before its first run; catch up if a scan is overdue.
        if let next = nextAutomaticScan, next < Date() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let next = self.nextAutomaticScan, next < Date() else { return }
                    self.startScan(origin: .automatic)
                }
            }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }


    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

// MARK: - Alerts

extension AppModel {
    var unseenAlertCount: Int { alertEvents.filter { $0.date > alertsSeen }.count }
    var activeAlertCount: Int { alerts.filter { $0.enabled && alertStates[$0.id]?.triggered == true }.count }

    func ruleName(_ id: UUID) -> String { rule(for: id)?.name ?? "Removed rule" }

    /// Free-space alerts don't need a scan: check the volume every few minutes.
    private func startDiskMonitor() {
        checkDiskAlerts()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.checkDiskAlerts() }
        }
        diskTimer?.tolerance = 60
    }

    func checkDiskAlerts() {
        guard let cap = volumeCapacity() else { return }
        let disk = DiskReading(free: cap.free, total: cap.total)
        var states = alertStates
        var events: [AlertEvent] = []
        for alert in alerts where alert.enabled && !alert.kind.needsScan {
            var state = states[alert.id] ?? AlertState()
            if let e = AlertEvaluator.evaluate(alert, state: &state, disk: disk, now: Date()) { events.append(e) }
            states[alert.id] = state
        }
        commit(states, events)
    }

    private func checkScanAlerts(_ result: ScanResult) {
        var ruleTotals: [UUID: Int64] = [:]
        for m in result.matches { if let id = m.ruleID { ruleTotals[id, default: 0] += m.size } }
        let rootPath = result.root.path
        let reading = ScanReading(
            date: result.date, root: rootPath, total: result.root.size,
            topGrowth: topGrowth(result),
            folderSize: { [weak self] path in
                guard path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
                return self?.node(at: path)?.size ?? 0
            },
            ruleTotal: { ruleTotals[$0] ?? 0 },
            ruleName: { [weak self] in self?.ruleName($0) ?? "Rule" })
        var states = alertStates
        var events: [AlertEvent] = []
        for alert in alerts where alert.enabled && alert.kind.needsScan {
            var state = states[alert.id] ?? AlertState()
            if let e = AlertEvaluator.evaluate(alert, state: &state, scan: reading) { events.append(e) }
            states[alert.id] = state
        }
        commit(states, events)
    }

    /// The biggest growth spot, found with the smallest "any folder" alert threshold so alerts
    /// below the Growth list's display threshold still fire.
    private func topGrowth(_ result: ScanResult) -> GrowthItem? {
        guard let previousSnapshot else { return nil }
        let floor = alerts.filter { $0.enabled && $0.kind == .growth && $0.scope == .anything }.map(\.bytes).min()
        guard let floor else { return report?.items.first }
        return Growth.compute(root: result.root, previous: previousSnapshot, minDelta: min(floor, growthThreshold)).first
    }

    private func commit(_ states: [UUID: AlertState], _ events: [AlertEvent]) {
        if states != alertStates {
            alertStates = states
            Store.save(states, to: "alert-state.json")
        }
        guard !events.isEmpty else { return }
        alertEvents = Array((events + alertEvents).prefix(100))
        Store.save(alertEvents, to: "alert-events.json")
        if notificationsEnabled { events.forEach(postNotification) }
    }

    private func postNotification(_ event: AlertEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.userInfo = ["pane": Pane.alerts.rawValue]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }

    func clearAlertEvents() {
        alertEvents = []
        Store.save(alertEvents, to: "alert-events.json")
    }

    /// Lets an edited alert start fresh (new thresholds shouldn't inherit the old trigger state).
    func saveAlert(_ alert: DiskAlert) {
        alertStates[alert.id]?.triggered = false
        if let i = alerts.firstIndex(where: { $0.id == alert.id }) { alerts[i] = alert } else { alerts.append(alert) }
    }
}
