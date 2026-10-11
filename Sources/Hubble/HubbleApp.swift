import SwiftUI
import UserNotifications

@main
struct HubbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Hubble", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.isScanning ? "Cancel Scan" : "Scan") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
                .keyboardShortcut("r")
            }
        }

        MenuBarExtra(isInserted: $model.showInMenuBar) {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Keeps Hubble alive with no window open (so scheduled scans keep running) and routes notification clicks.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let pane = (response.notification.request.content.userInfo["pane"] as? String).flatMap(Pane.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppModel.shared.requestedPane = pane ?? .overview
                AppModel.shared.showMainWindow()
            }
            completionHandler()
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview, growth, cleanup, explore, files, alerts, rules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .growth: "Since Last Scan"
        case .cleanup: "Cleanup"
        case .explore: "Explore"
        case .files: "Largest Files"
        case .alerts: "Alerts"
        case .rules: "Rules"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .growth: "chart.line.uptrend.xyaxis"
        case .cleanup: "sparkles"
        case .explore: "folder"
        case .files: "doc.on.doc"
        case .alerts: "bell.badge"
        case .rules: "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Insights") {
                    row(.overview)
                    row(.growth, badge: model.report?.items.count ?? 0)
                    row(.cleanup, badge: model.result?.matches.count ?? 0)
                }
                Section("Browse") {
                    row(.explore)
                    row(.files)
                }
                Section("Configure") {
                    row(.alerts, badge: model.unseenAlertCount)
                    row(.rules)
                }
            }
            .safeAreaInset(edge: .bottom) { ScanPanel().padding(12) }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            switch pane ?? .overview {
            case .overview: OverviewView(pane: $pane)
            case .growth: GrowthView()
            case .cleanup: CleanupView()
            case .explore: ExploreView()
            case .files: LargestFilesView()
            case .alerts: AlertsView()
            case .rules: RulesView()
            }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            if let p = model.requestedPane {
                pane = p
                model.requestedPane = nil
            }
        }
        .onChange(of: model.requestedPane) {
            if let p = model.requestedPane {
                pane = p
                model.requestedPane = nil
            }
        }
        .confirmationDialog(trashTitle, isPresented: trashBinding, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text(trashMessage)
        }
        .alert("Some items couldn't be moved", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func row(_ p: Pane, badge: Int = 0) -> some View {
        Label(p.title, systemImage: p.icon)
            .badge(badge)
            .tag(p)
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { !model.pendingTrash.isEmpty }, set: { if !$0 { model.pendingTrash = [] } })
    }

    private var trashTitle: String {
        let items = model.pendingTrash
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        return items.count == 1
            ? "Move “\(items[0].name)” (\(total.bytes)) to the Trash?"
            : "Move \(items.count) items (\(total.bytes)) to the Trash?"
    }

    private var trashMessage: String {
        model.pendingTrash.prefix(6).map { abbreviate($0.path) }.joined(separator: "\n")
            + (model.pendingTrash.count > 6 ? "\n…and \(model.pendingTrash.count - 6) more" : "")
    }
}

struct ScanPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                Button("Home folder") { model.rootPath = NSHomeDirectory() }
                Button("Entire disk") { model.rootPath = AppModel.diskRoot }
                Divider()
                Button("Choose folder…") { model.chooseFolder() }
            } label: {
                Label(model.rootDisplayName, systemImage: "internaldrive")
            }
            .menuStyle(.borderlessButton)
            .disabled(model.isScanning)
            .help(model.rootPath)

            if model.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().progressViewStyle(.linear)
                    if model.scanOrigin == .automatic {
                        Text("Automatic scan · low priority").font(.caption2).foregroundStyle(.secondary)
                    }
                    ScanProgressText(activity: model.activity)
                }
                Button("Cancel") { model.cancelScan() }
                    .frame(maxWidth: .infinity)
            } else {
                Button { model.startScan() } label: {
                    Label("Scan", systemImage: "scope")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                if let last = model.lastScan {
                    Text("Last scan \(relative(last.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let next = model.nextAutomaticScan {
                    Text("Next automatic scan \(next < Date() ? "soon" : relative(next))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Observes only the fast-changing progress counters.
struct ScanProgressText: View {
    @ObservedObject var activity: ScanActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(activity.files.formatted()) files · \(activity.bytes.bytes)")
                .font(.caption.monospacedDigit())
            Text(abbreviate(activity.path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
