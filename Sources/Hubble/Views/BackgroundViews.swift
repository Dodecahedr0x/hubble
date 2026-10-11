import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.isScanning ? "scope" : "internaldrive")
            .symbolEffect(.pulse, isActive: model.isScanning)
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let cap = model.volumeCapacity() {
            Text("\(cap.free.bytes) free of \(cap.total.bytes)")
        }
        if model.isScanning {
            Text(model.scanOrigin == .automatic ? "Automatic scan in progress…" : "Scanning…")
            Button("Cancel Scan") { model.cancelScan() }
        } else {
            if let last = model.lastScan {
                Text("Last scan \(relative(last.date))")
            }
            Button("Scan \(model.rootDisplayName) Now") { model.startScan() }
                .keyboardShortcut("r")
        }

        if let report = model.report, let top = report.items.first {
            Divider()
            Text("Heaviest addition since last scan")
            Button("\(top.name)  +\(top.delta.bytes)") {
                model.requestedPane = .growth
                model.showMainWindow()
            }
            if report.items.count > 1 {
                Text("\(report.items.count - 1) more growth spots")
            }
        }

        if model.activeAlertCount > 0 {
            Divider()
            Button("⚠︎ \(model.activeAlertCount) active alert\(model.activeAlertCount == 1 ? "" : "s")") {
                model.requestedPane = .alerts
                model.showMainWindow()
            }
        }

        Divider()
        Picker("Automatic Scans", selection: $model.autoScan) {
            ForEach(AutoScanInterval.allCases) { Text($0.label).tag($0) }
        }
        Button("Open Hubble") { model.showMainWindow() }
            .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Hubble") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Scan automatically", selection: $model.autoScan) {
                    ForEach(AutoScanInterval.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("What") {
                    Text(abbreviate(model.rootPath)).foregroundStyle(.secondary)
                }
                if let next = model.nextAutomaticScan {
                    LabeledContent("Next scan") {
                        Text(next < Date() ? "Soon" : next.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Background scans")
            } footer: {
                Text("Automatic scans run at low priority, and macOS picks a moment when your Mac is idle and not short on battery. Hubble keeps running when its window is closed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Send notifications when an alert fires", isOn: $model.notificationsEnabled)
                LabeledContent("Alerts") {
                    Text("\(model.alerts.filter(\.enabled).count) active").foregroundStyle(.secondary)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Set up disk usage and growth alerts in the Alerts tab of the main window.")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show in menu bar", isOn: $model.showInMenuBar)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin },
                                                     set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}
