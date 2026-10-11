import SwiftUI

struct ExploreView: View {
    @EnvironmentObject var model: AppModel
    @State private var stack: [FileNode] = []

    var body: some View {
        if let result = model.result {
            let current = stack.last ?? result.root
            VStack(spacing: 0) {
                PaneHeader(title: current.name, subtitle: "\(current.size.bytes) · \(abbreviate(current.path))") {
                    breadcrumb(root: result.root)
                }
                List {
                    ForEach(current.children) { child in
                        let drillable = child.isDirectory && (!child.children.isEmpty || child.otherCount > 0)
                        Button {
                            if drillable { stack.append(child) }
                        } label: {
                            ItemRow(path: child.path,
                                    title: child.name,
                                    subtitle: subtitle(child),
                                    size: child.size.bytes,
                                    fraction: Double(child.size) / Double(max(current.size, 1)),
                                    badges: badges(child),
                                    showsChevron: drillable)
                        }
                        .buttonStyle(.plain)
                        .pathActions(child.path, node: child)
                    }
                    if current.otherSize > 0 {
                        ItemRow(path: current.path,
                                title: "\(current.otherCount.formatted()) smaller items",
                                subtitle: "Each under 1 MB",
                                size: current.otherSize.bytes,
                                fraction: Double(current.otherSize) / Double(max(current.size, 1)))
                            .opacity(0.6)
                    }
                }
                .listStyle(.inset)
                .animation(.snappy, value: stack.count)
            }
            .onChange(of: result.id) { stack = [] }
        } else {
            NeedsScanView()
        }
    }

    private func breadcrumb(root: FileNode) -> some View {
        HStack(spacing: 8) {
            Button { _ = stack.popLast() } label: { Image(systemName: "chevron.left") }
                .disabled(stack.isEmpty)
                .keyboardShortcut("[", modifiers: .command)
            Button { stack = [] } label: { Image(systemName: "house") }
                .disabled(stack.isEmpty)
        }
        .controlSize(.large)
    }

    private func subtitle(_ n: FileNode) -> String {
        var parts: [String] = []
        if n.isDirectory { parts.append("\(n.children.count + n.otherCount) items") }
        if let m = n.modified { parts.append("modified \(relative(m))") }
        return parts.joined(separator: " · ")
    }

    private func badges(_ n: FileNode) -> [(String, Color)] {
        guard let rule = model.rule(for: n.ruleID) else { return [] }
        return [(rule.name, Theme.cleanup)]
    }
}

struct LargestFilesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let result = model.result {
            let files = result.topFiles
            let maxSize = files.first?.size ?? 1
            VStack(spacing: 0) {
                PaneHeader(title: "Largest Files",
                           subtitle: "\(files.count) files over \(DiskScanner.topFileThreshold.bytes) in \(abbreviate(result.root.path))")
                List(files) { f in
                    ItemRow(path: f.path,
                            title: f.name,
                            subtitle: "\(abbreviate(f.parent?.path ?? "")) · modified \(relative(f.modified))",
                            size: f.size.bytes,
                            fraction: Double(f.size) / Double(max(maxSize, 1)))
                        .pathActions(f.path, node: f)
                }
                .listStyle(.inset)
            }
        } else {
            NeedsScanView()
        }
    }
}

struct GrowthView: View {
    @EnvironmentObject var model: AppModel
    private let thresholds: [Int64] = [10 << 20, 50 << 20, 100 << 20, 500 << 20, 1 << 30]

    var body: some View {
        if let report = model.report {
            let maxDelta = report.items.first?.delta ?? 1
            VStack(spacing: 0) {
                PaneHeader(title: "Since Last Scan", subtitle: subtitle(report)) {
                    Picker("Min growth", selection: $model.growthThreshold) {
                        ForEach(thresholds, id: \.self) { Text($0.bytes).tag($0) }
                    }
                    .frame(width: 170)
                }
                if report.items.isEmpty {
                    ContentUnavailableView("Nothing grew by more than \(model.growthThreshold.bytes)",
                                           systemImage: "checkmark.seal",
                                           description: Text("Your disk usage is stable."))
                } else {
                    List(report.items) { item in
                        ItemRow(path: item.path,
                                title: item.name,
                                subtitle: "\(abbreviate(item.path)) · now \(item.size.bytes)",
                                size: "+\(item.delta.bytes)",
                                fraction: Double(item.delta) / Double(max(maxDelta, 1)),
                                badges: item.isNew ? [("NEW", Theme.growth)] : [],
                                sizeColor: Theme.growth)
                            .pathActions(item.path, node: model.node(at: item.path))
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            NeedsScanView(title: "No comparison yet",
                          message: model.lastScan == nil
                              ? "Scan once to set a baseline. The next scan will show what grew."
                              : "Scan again to see what grew since \(relative(model.lastScan?.date)).")
        }
    }

    private func subtitle(_ r: GrowthReport) -> String {
        let sign = r.totalDelta >= 0 ? "+" : "−"
        let since = r.previousDate.map { "since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(sign)\(abs(r.totalDelta).bytes) overall \(since) · where the growth concentrated"
    }
}
