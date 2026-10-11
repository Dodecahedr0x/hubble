import SwiftUI

struct AlertsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: DiskAlert?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Alerts",
                       subtitle: "Disk space is checked every 5 minutes; growth and sizes after each scan.") {
                Menu {
                    ForEach(DiskAlert.Kind.allCases) { kind in
                        Button(kind.label + "…") { editing = Self.newAlert(kind) }
                    }
                } label: {
                    Label("Add Alert", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }
            List {
                Section("Your alerts") {
                    if model.alerts.isEmpty {
                        Text("No alerts. Add one to get notified when your disk fills up.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($model.alerts) { $alert in
                        AlertRow(alert: $alert, state: model.alertStates[alert.id]) { editing = alert }
                            .contextMenu {
                                Button("Edit…") { editing = alert }
                                Button("Delete", role: .destructive) { model.alerts.removeAll { $0.id == alert.id } }
                            }
                    }
                    .onDelete { model.alerts.remove(atOffsets: $0) }
                }
                Section {
                    if model.alertEvents.isEmpty {
                        Text("Nothing has fired yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.alertEvents) { event in
                        EventRow(event: event)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        if !model.alertEvents.isEmpty {
                            Button("Clear") { model.clearAlertEvents() }.buttonStyle(.link)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .sheet(item: $editing) { alert in
            AlertEditor(alert: alert) { model.saveAlert($0) }
        }
        .onAppear { model.alertsSeen = Date() }
        .onChange(of: model.alertEvents) { model.alertsSeen = Date() }
    }

    static func newAlert(_ kind: DiskAlert.Kind) -> DiskAlert {
        switch kind {
        case .freeSpaceBelow: DiskAlert(kind: kind, bytes: 20 << 30)
        case .usageAbove: DiskAlert(kind: kind, percent: 90)
        case .growth: DiskAlert(kind: kind, scope: .anything, bytes: 5 << 30)
        case .sizeAbove: DiskAlert(kind: kind, scope: .total, bytes: 100 << 30)
        }
    }
}

private struct AlertRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var alert: DiskAlert
    let state: AlertState?
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $alert.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Image(systemName: alert.icon)
                .font(.title3)
                .foregroundStyle(triggered ? Theme.growth : Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.summary(ruleName: model.ruleName)).fontWeight(.medium)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if alert.enabled {
                Badge(text: triggered ? "Triggered" : "OK", color: triggered ? Theme.growth : Theme.cleanup)
            }
            Button("Edit", action: onEdit).buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .opacity(alert.enabled ? 1 : 0.5)
    }

    private var triggered: Bool { alert.enabled && state?.triggered == true }

    private var status: String {
        var parts: [String] = []
        switch alert.kind {
        case .freeSpaceBelow, .usageAbove:
            if let cap = model.volumeCapacity() {
                let pct = Int(Double(cap.total - cap.free) / Double(max(cap.total, 1)) * 100)
                parts.append("Now \(cap.free.bytes) free · \(pct)% full")
            }
        case .growth:
            if model.lastScan == nil {
                parts.append("Needs a scan")
            } else if let v = state?.lastValue {
                parts.append("Last measured change \(v >= 0 ? "+" : "−")\(abs(v).bytes)")
            } else {
                parts.append("Starts tracking at the next scan")
            }
        case .sizeAbove:
            if let v = state?.lastValue { parts.append("Now \(v.bytes)") } else { parts.append("Measured at the next scan") }
        }
        if let fired = state?.lastFired { parts.append("last fired \(relative(fired))") }
        return parts.joined(separator: " · ")
    }
}

private struct EventRow: View {
    @EnvironmentObject var model: AppModel
    let event: AlertEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.fill").foregroundStyle(Theme.growth).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).fontWeight(.medium)
                Text(event.body).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(relative(event.date)).font(.caption).foregroundStyle(.secondary)
                if let path = event.path {
                    Button("Reveal") { model.reveal(path) }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct AlertEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var alert: DiskAlert
    let onSave: (DiskAlert) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alert").font(.title2.bold()).padding([.horizontal, .top], 20)
            Form {
                Picker("Notify me when", selection: $alert.kind) {
                    ForEach(DiskAlert.Kind.allCases) { Text($0.label.lowercased()).tag($0) }
                }
                .onChange(of: alert.kind) { fixScope() }

                switch alert.kind {
                case .freeSpaceBelow:
                    LabeledContent("Free space below") { ByteField(bytes: $alert.bytes) }
                case .usageAbove:
                    LabeledContent("Usage above") {
                        HStack {
                            Slider(value: $alert.percent, in: 50...99, step: 1)
                            Text("\(Int(alert.percent))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                case .growth, .sizeAbove:
                    scopePicker
                    LabeledContent(alert.kind == .growth ? "Grows by more than" : "Larger than") {
                        ByteField(bytes: $alert.bytes)
                    }
                    if alert.kind == .growth && alert.scope != .anything {
                        Picker("Within", selection: $alert.window) {
                            ForEach(DiskAlert.Window.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }

                Section {
                    Label(alert.summary(ruleName: model.ruleName), systemImage: alert.icon)
                        .foregroundStyle(.secondary)
                    if alert.kind.needsScan {
                        Text("Checked after each scan of \(abbreviate(model.rootPath)). Turn on automatic scans in Settings to be alerted without scanning by hand.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(alert)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    private var isValid: Bool {
        switch alert.kind {
        case .usageAbove: true
        default: alert.bytes > 0
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        Picker("What", selection: $alert.scope) {
            if alert.kind == .growth {
                Text("Any single folder or file").tag(DiskAlert.Scope.anything)
            }
            Text("Everything scanned").tag(DiskAlert.Scope.total)
            if case .folder(let p) = alert.scope {
                Text((p as NSString).lastPathComponent).tag(alert.scope)
            }
            let categories = model.rules.filter { $0.action == .prioritize }
            if !categories.isEmpty {
                Divider()
                ForEach(categories) { r in
                    Text("All “\(r.name)” folders").tag(DiskAlert.Scope.rule(r.id))
                }
            }
        }
        LabeledContent("Folder") {
            HStack {
                if case .folder(let p) = alert.scope {
                    Text(abbreviate(p)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button("Choose Folder…") { chooseFolder() }
            }
        }
    }

    private func fixScope() {
        if alert.kind == .sizeAbove && alert.scope == .anything { alert.scope = .total }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.rootPath)
        if panel.runModal() == .OK, let url = panel.url { alert.scope = .folder(url.path) }
    }
}

/// Edits a byte count as an amount plus a unit.
struct ByteField: View {
    @Binding var bytes: Int64
    @State private var amount: Double
    @State private var unit: Int64

    private static let units: [(String, Int64)] = [("MB", 1 << 20), ("GB", 1 << 30), ("TB", 1 << 40)]

    init(bytes: Binding<Int64>) {
        _bytes = bytes
        let b = bytes.wrappedValue
        let unit: Int64 = b >= 1 << 40 ? 1 << 40 : b >= 1 << 30 ? 1 << 30 : 1 << 20
        _unit = State(initialValue: unit)
        _amount = State(initialValue: Double(b) / Double(unit))
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $amount, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Picker("", selection: $unit) {
                ForEach(Self.units, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: amount) { update() }
        .onChange(of: unit) { update() }
    }

    private func update() { bytes = Int64(max(0, amount) * Double(unit)) }
}
