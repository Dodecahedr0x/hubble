import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: Pane?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Overview", subtitle: subtitle).padding(.horizontal, -24)

                HStack(alignment: .top, spacing: 18) {
                    diskCard
                    statsCard
                }
                heaviestCard
                if let result = model.result {
                    HStack(alignment: .top, spacing: 18) {
                        cleanupCard(result)
                        topFoldersCard(result)
                    }
                } else if model.lastScan == nil {
                    NeedsScanView(title: "Let's find what's eating your disk",
                                  message: "Hubble maps every folder, remembers the result, and tells you what grew next time.")
                        .frame(minHeight: 260)
                }
            }
            .padding(24)
        }
    }

    private var subtitle: String {
        guard let last = model.lastScan else { return abbreviate(model.rootPath) }
        return "\(abbreviate(model.rootPath)) · last scanned \(relative(last.date))"
    }

    private var diskCard: some View {
        Card {
            HStack(spacing: 22) {
                let cap = model.volumeCapacity()
                let used = cap.map { Double($0.total - $0.free) / Double(max($0.total, 1)) } ?? 0
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: used)
                        .stroke(AngularGradient(colors: [.indigo, .purple, .pink, .orange], center: .center),
                                style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(duration: 0.8), value: used)
                    VStack(spacing: 0) {
                        Text("\(Int(used * 100))%").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("used").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Disk").font(.headline)
                    if let cap {
                        stat("Free", cap.free.bytes, color: Theme.cleanup)
                        stat("Used", (cap.total - cap.free).bytes)
                        stat("Capacity", cap.total.bytes)
                    }
                }
            }
        }
    }

    private var statsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Last scan").font(.headline)
                if let r = model.result {
                    stat("Scanned", r.root.size.bytes)
                    stat("Files", r.fileCount.formatted())
                    stat("Took", String(format: "%.1fs", r.duration))
                    if r.unreadable > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                            Text("\(r.unreadable) folders unreadable").font(.caption).foregroundStyle(.secondary)
                            Button("Grant Full Disk Access") { model.openFullDiskAccessSettings() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                } else if let last = model.lastScan {
                    stat("Scanned", last.totalSize.bytes)
                    stat("Files", last.fileCount.formatted())
                    Text("Scan again to browse results.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Nothing scanned yet.").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var heaviestCard: some View {
        if let report = model.report, report.root == model.rootPath {
            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Heaviest addition since last scan", systemImage: "arrow.up.right.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.growth)
                        Spacer()
                        if let prev = report.previousDate {
                            Text("vs. \(prev.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let top = report.items.first {
                        HStack(spacing: 16) {
                            Image(nsImage: Icons.icon(for: top.path)).resizable().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(top.name).font(.title2.weight(.semibold)).lineLimit(1)
                                    if top.isNew { Badge(text: "NEW", color: Theme.growth) }
                                }
                                Text(abbreviate(top.path)).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("+\(top.delta.bytes)")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.growth)
                                Text("now \(top.size.bytes)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .pathActions(top.path)
                        HStack {
                            Text("Overall change: \(report.totalDelta >= 0 ? "+" : "−")\(abs(report.totalDelta).bytes) · \(report.items.count) growth spots")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reveal") { model.reveal(top.path) }
                            Button("See all") { pane = .growth }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text("Nothing grew by more than \(model.growthThreshold.bytes) — nice.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if model.result != nil {
            Card {
                Label("This is the first scan of \(model.rootDisplayName). Next time, Hubble will show what grew.",
                      systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cleanupCard(_ result: ScanResult) -> some View {
        let groups = Dictionary(grouping: result.matches) { $0.ruleID }
            .map { (rule: model.rule(for: $0.key), total: $0.value.reduce(Int64(0)) { $0 + $1.size }, count: $0.value.count) }
            .sorted { $0.total > $1.total }
        let total = groups.reduce(Int64(0)) { $0 + $1.total }
        let maxTotal = groups.first?.total ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Cleanup candidates", systemImage: "sparkles").font(.headline)
                    Spacer()
                    Text(total.bytes).font(.title3.weight(.bold)).foregroundStyle(Theme.cleanup)
                }
                if groups.isEmpty {
                    Text("No rule matches. Add rules for folders you can safely delete.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(groups.prefix(6), id: \.rule?.id) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(g.rule?.name ?? "Unknown").font(.callout)
                            Text("\(g.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(g.total.bytes).font(.callout.monospacedDigit())
                        }
                        SizeBar(fraction: Double(g.total) / Double(max(maxTotal, 1)),
                                tint: AnyShapeStyle(Theme.cleanup.gradient))
                    }
                }
                if !groups.isEmpty {
                    Button("Review cleanup") { pane = .cleanup }
                }
            }
        }
    }

    private func topFoldersCard(_ result: ScanResult) -> some View {
        let items = result.root.children.prefix(7)
        let maxSize = items.first?.size ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Biggest in \(result.root.name)", systemImage: "folder.fill").font(.headline)
                ForEach(Array(items)) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(nsImage: Icons.icon(for: n.path)).resizable().frame(width: 16, height: 16)
                            Text(n.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text(n.size.bytes).font(.callout.monospacedDigit())
                        }
                        SizeBar(fraction: Double(n.size) / Double(max(maxSize, 1)))
                    }
                    .pathActions(n.path, node: n)
                }
                Button("Explore") { pane = .explore }
            }
        }
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color)
        }
        .font(.callout)
    }
}
