import SwiftUI

struct CleanupView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<ObjectIdentifier>()
    @State private var sortByAge = false

    private struct Group: Identifiable {
        let id: UUID?
        let rule: Rule?
        let nodes: [FileNode]
        let total: Int64
    }

    var body: some View {
        if let result = model.result {
            let groups = makeGroups(result.matches)
            let total = groups.reduce(Int64(0)) { $0 + $1.total }
            VStack(spacing: 0) {
                PaneHeader(title: "Cleanup",
                           subtitle: "\(total.bytes) in \(result.matches.count) folders matched by your rules") {
                    Picker("Sort", selection: $sortByAge) {
                        Text("Largest").tag(false)
                        Text("Oldest").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                if groups.isEmpty {
                    ContentUnavailableView("No cleanup candidates",
                                           systemImage: "sparkles",
                                           description: Text("Add rules for folders that are safe to delete, like build outputs and caches."))
                } else {
                    List {
                        ForEach(groups) { g in
                            Section {
                                ForEach(g.nodes) { n in row(n) }
                            } header: {
                                header(g)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .safeAreaInset(edge: .bottom) { if !selected(result).isEmpty { actionBar(result) } }
            .onChange(of: result.id) { selection = [] }
        } else {
            NeedsScanView()
        }
    }

    private func makeGroups(_ matches: [FileNode]) -> [Group] {
        Dictionary(grouping: matches) { $0.ruleID }
            .map { key, nodes in
                let sorted = sortByAge
                    ? nodes.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                    : nodes.sorted { $0.size > $1.size }
                return Group(id: key, rule: model.rule(for: key), nodes: sorted,
                             total: nodes.reduce(Int64(0)) { $0 + $1.size })
            }
            .sorted { $0.total > $1.total }
    }

    private func row(_ n: FileNode) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(n.id) },
                set: { if $0 { selection.insert(n.id) } else { selection.remove(n.id) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            ItemRow(path: n.path,
                    title: projectName(n),
                    subtitle: "\(abbreviate(n.path)) · modified \(relative(n.modified))",
                    size: n.size.bytes,
                    fraction: Double(n.size) / Double(max(n.parent?.size ?? n.size, 1)),
                    badges: [])
        }
        .pathActions(n.path, node: n)
    }

    /// For `target` / `node_modules` the interesting name is the project folder.
    private func projectName(_ n: FileNode) -> String {
        guard let p = n.parent, n.name.first != "~" else { return n.name }
        return "\(p.name)/\(n.name)"
    }

    private func header(_ g: Group) -> some View {
        let ids = Set(g.nodes.map(\.id))
        let all = ids.isSubset(of: selection)
        return HStack {
            Text(g.rule?.name ?? "Rule removed").font(.headline)
            Text("\(g.nodes.count) · \(g.total.bytes)").foregroundStyle(.secondary)
            Spacer()
            Button(all ? "Deselect all" : "Select all") {
                if all { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 4)
    }

    private func selected(_ result: ScanResult) -> [FileNode] {
        result.matches.filter { selection.contains($0.id) }
    }

    private func actionBar(_ result: ScanResult) -> some View {
        let nodes = selected(result)
        let total = nodes.reduce(Int64(0)) { $0 + $1.size }
        return HStack {
            Text("\(nodes.count) selected").fontWeight(.semibold)
            Text("· frees \(total.bytes)").foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { selection = [] }
            Button(role: .destructive) {
                model.requestTrash(nodes)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
