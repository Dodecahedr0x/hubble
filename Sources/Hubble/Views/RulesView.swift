import SwiftUI

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Rule?
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Rules", subtitle: "Prioritize folders you can safely remove, or ignore folders you never want scanned. Applies on the next scan.") {
                HStack {
                    Menu("Restore Defaults") {
                        Button("Add missing defaults") {
                            let names = Set(model.rules.map(\.pattern))
                            model.rules += Rule.defaults.filter { !names.contains($0.pattern) }
                        }
                        Button("Replace all with defaults", role: .destructive) { model.rules = Rule.defaults }
                    }
                    .fixedSize()
                    Button {
                        isNew = true
                        editing = Rule(name: "", pattern: "")
                    } label: { Label("Add Rule", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            List {
                ForEach($model.rules) { $rule in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Image(systemName: rule.action == .ignore ? "eye.slash" : "sparkles")
                            .foregroundStyle(rule.action == .ignore ? Color.secondary : Theme.cleanup)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name).fontWeight(.medium)
                            HStack(spacing: 6) {
                                Text(rule.pattern).font(.caption.monospaced())
                                if !rule.requiresSibling.isEmpty {
                                    Text("next to \(rule.requiresSibling)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Badge(text: rule.action.label, color: rule.action == .ignore ? .secondary : Theme.cleanup)
                        Button("Edit") { isNew = false; editing = rule }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                    .opacity(rule.enabled ? 1 : 0.5)
                    .contextMenu {
                        Button("Edit") { isNew = false; editing = rule }
                        Button("Delete", role: .destructive) { model.rules.removeAll { $0.id == rule.id } }
                    }
                }
                .onDelete { model.rules.remove(atOffsets: $0) }
                .onMove { model.rules.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: isNew) { saved in
                if let i = model.rules.firstIndex(where: { $0.id == saved.id }) {
                    model.rules[i] = saved
                } else {
                    model.rules.append(saved)
                }
            }
        }
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let isNew: Bool
    let onSave: (Rule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Rule" : "Edit Rule").font(.title2.bold()).padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $rule.name, prompt: Text("Rust build output"))
                TextField("Pattern", text: $rule.pattern, prompt: Text("target  ·  node_modules  ·  ~/Library/Caches"))
                    .font(.body.monospaced())
                TextField("Only if next to", text: $rule.requiresSibling, prompt: Text("Cargo.toml (optional)"))
                    .font(.body.monospaced())
                Picker("Action", selection: $rule.action) {
                    ForEach(RuleAction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        tip("A plain name or glob matches any folder with that name: `node_modules`, `*.xcarchive`.")
                        tip("A pattern containing `/` matches a full path: `~/Library/Caches`, `~/Projects/*/build`.")
                        tip("“Only if next to” requires a sibling entry, so `target` only matches Rust projects.")
                        tip("Cleanup candidates are listed under Cleanup; ignored folders are skipped entirely.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.pattern }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    private func tip(_ s: String) -> some View {
        Text(.init("• " + s))
    }
}
