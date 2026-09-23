import AppKit
import SwiftUI
import PrizmXServices

/// Script catalog. Add / edit opens a sheet; HTTP matching is stored, not hooked.
struct ScriptsPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var search = ""
    @State private var selectedID: ScriptRecord.ID?
    @State private var editor: ScriptRecord?
    @State private var errorMessage: String?

    var body: some View {
        let rows = displayScripts
        Group {
            if rows.isEmpty {
                ConsoleEmptyState(
                    title: "No Scripts",
                    systemImage: SidebarItem.scripts.systemImage,
                    description: search.isEmpty
                        ? (store.lastError ?? "Add a script to run JavaScript on matching requests.")
                        : "No scripts match this filter."
                )
            } else {
                Table(rows, selection: $selectedID) {
                    TableColumn("Name") { (script: ScriptRecord) in
                        HStack(spacing: 6) {
                            Text(script.name)
                            if !script.enabled {
                                Text("Off")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Type") { script in
                        Text(script.kind.title)
                    }
                    .width(140)
                    TableColumn("Match") { script in
                        Text(script.kind.showsMatch ? displayMatch(script.pattern) : "—")
                            .font(.body.monospaced())
                            .foregroundStyle(script.pattern.isEmpty ? .tertiary : .primary)
                    }
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: ScriptRecord.ID.self) { ids in
                    if let id = ids.first, let script = store.scripts.first(where: { $0.id == id }) {
                        Button("Edit…") { editor = script }
                        Button("Duplicate") { duplicate(script) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(id: id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first {
                        editor = store.scripts.first { $0.id == id }
                    }
                }
            }
        }
        .navigationTitle("Scripts \(rows.count)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Button("Add Script", systemImage: "plus") {
                        editor = ScriptRecord(name: "New Script", source: ScriptRecord.sampleSource)
                    }
                    .help("Add")
                    Button("Delete", systemImage: "minus") {
                        delete(id: selectedID)
                    }
                    .disabled(selectedID == nil)
                    .help("Delete")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: "Search scripts")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: $editor) { script in
            ScriptEditorSheet(
                title: store.scripts.contains(where: { $0.id == script.id }) ? "Edit Script" : "Add Script",
                initial: script
            ) { saved in
                upsert(saved)
            }
        }
        .sheet(isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            ConfirmSheet(
                title: "Error",
                message: errorMessage ?? "",
                showsCancel: false,
                onDone: { errorMessage = nil }
            )
        }
    }

    private var store: ScriptStore { appModel.scripts }

    private var displayScripts: [ScriptRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.scripts }
        return store.scripts.filter { script in
            script.name.localizedCaseInsensitiveContains(query)
                || script.kind.title.localizedCaseInsensitiveContains(query)
                || script.pattern.localizedCaseInsensitiveContains(query)
        }
    }

    private func displayMatch(_ pattern: String) -> String {
        pattern.isEmpty ? "—" : pattern
    }

    private func upsert(_ script: ScriptRecord) {
        do {
            try store.upsert(script)
            selectedID = script.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicate(_ script: ScriptRecord) {
        var copy = script
        copy.id = UUID()
        copy.name = "\(script.name) copy"
        upsert(copy)
    }

    private func delete(id: ScriptRecord.ID?) {
        guard let id else { return }
        do {
            try store.remove(id: id)
            if selectedID == id { selectedID = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var initial: ScriptRecord
    var onSave: (ScriptRecord) -> Void

    @State private var name: String
    @State private var enabled: Bool
    @State private var kind: ScriptRecord.Kind
    @State private var pattern: String
    @State private var source: String
    @State private var argument: String
    @State private var timeout: Double
    @State private var output = ""
    @State private var isRunning = false
    @State private var engine = ScriptEngine()

    init(title: String, initial: ScriptRecord, onSave: @escaping (ScriptRecord) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial.name)
        _enabled = State(initialValue: initial.enabled)
        _kind = State(initialValue: initial.kind)
        _pattern = State(initialValue: initial.pattern)
        _source = State(initialValue: initial.source)
        _argument = State(initialValue: initial.argument)
        _timeout = State(initialValue: initial.timeout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $kind) {
                    ForEach(ScriptRecord.Kind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                if kind.showsMatch {
                    TextField(kind.matchPrompt, text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                TextField("Argument", text: $argument)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Timeout (s)", value: $timeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Spacer()
                    Toggle("Enabled", isOn: $enabled)
                }
            }
            .formStyle(.grouped)

            Text("Source")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                )

            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 88)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(
                doneTitle: "Save",
                doneEnabled: canSave,
                onDone: save
            ) {
                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(isRunning ? "Running…" : "Run") { run() }
                    .disabled(isRunning || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Evaluate with JavaScriptCore")
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && timeout > 0
    }

    private var draft: ScriptRecord {
        var next = initial
        next.name = name
        next.enabled = enabled
        next.kind = kind
        next.pattern = pattern
        next.source = source
        next.argument = argument
        next.timeout = timeout
        return next
    }

    private func save() {
        onSave(draft)
        dismiss()
    }

    private func run() {
        isRunning = true
        output = "Running…"
        let request = draft.request
        Task {
            do {
                let result = try await engine.evaluate(request)
                var lines = ["result: \(result.value.jsonString)"]
                if !result.logs.isEmpty {
                    lines.append("logs:")
                    lines.append(contentsOf: result.logs.map { "  \($0)" })
                }
                output = lines.joined(separator: "\n")
            } catch {
                output = error.localizedDescription
            }
            isRunning = false
        }
    }
}

#Preview("Scripts") {
    ScriptsPane()
        .environment(AppModel.preview)
        .frame(width: 720, height: 480)
}
