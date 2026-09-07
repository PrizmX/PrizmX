import SwiftUI
import PrizmXConfig
import PrizmXNodes

struct OverlayRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var policies: [String]
    var initial: OverlayRule
    var onSave: (OverlayRule) -> Void

    @State private var type: OverlayRule.Kind
    @State private var payload: String
    @State private var policy: String
    @State private var noResolve: Bool

    init(
        title: String,
        policies: [String],
        initial: OverlayRule,
        onSave: @escaping (OverlayRule) -> Void
    ) {
        self.title = title
        self.policies = policies
        self.initial = initial
        self.onSave = onSave
        _type = State(initialValue: initial.type)
        _payload = State(initialValue: initial.payload)
        _policy = State(initialValue: initial.policy)
        _noResolve = State(initialValue: initial.noResolve)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                Picker("Type", selection: $type) {
                    ForEach(OverlayRule.Kind.allCases) { kind in
                        Text(kind.clashType).tag(kind)
                    }
                }
                if type != .matchAll {
                    TextField("Payload", text: $payload)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("Policy", selection: $policy) {
                    ForEach(policyOptions, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                if type == .geoIP || type == .ipCIDR {
                    Toggle("no-resolve", isOn: $noResolve)
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(minWidth: 420)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(
                doneTitle: "Save",
                doneEnabled: canSave,
                onDone: save
            ) {
                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var policyOptions: [String] {
        var names = policies
        if !names.contains(policy) { names.insert(policy, at: 0) }
        return names
    }

    private var canSave: Bool {
        type == .matchAll || !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var next = initial
        next.type = type
        next.payload = type == .matchAll ? "" : payload.trimmingCharacters(in: .whitespacesAndNewlines)
        next.policy = policy
        next.noResolve = noResolve
        onSave(next)
        dismiss()
    }
}

struct OverlayGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var memberChoices: [String]
    var initial: OverlayGroup
    var onSave: (OverlayGroup) -> Void

    @State private var name: String
    @State private var mode: String
    @State private var members: Set<String>
    @State private var testURL: String

    init(
        title: String,
        memberChoices: [String],
        initial: OverlayGroup,
        onSave: @escaping (OverlayGroup) -> Void
    ) {
        self.title = title
        self.memberChoices = memberChoices
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial.name)
        _mode = State(initialValue: initial.mode)
        _members = State(initialValue: Set(initial.members))
        _testURL = State(initialValue: initial.testURL ?? PolicyGroup.defaultTestURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Picker("Mode", selection: $mode) {
                    Text("select").tag("select")
                    Text("url-test").tag("url-test")
                    Text("fallback").tag("fallback")
                    Text("load-balance").tag("load-balance")
                }
                if mode != "select" {
                    TextField("Test URL", text: $testURL)
                        .textFieldStyle(.roundedBorder)
                }
                Section("Members") {
                    ForEach(memberChoices, id: \.self) { item in
                        Toggle(item, isOn: memberBinding(item))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 420)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(
                doneTitle: "Save",
                doneEnabled: canSave,
                onDone: save
            ) {
                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !members.isEmpty
    }

    private func memberBinding(_ item: String) -> Binding<Bool> {
        Binding(
            get: { members.contains(item) },
            set: { on in
                if on { members.insert(item) } else { members.remove(item) }
            }
        )
    }

    private func save() {
        var next = initial
        next.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.mode = mode
        next.members = memberChoices.filter { members.contains($0) }
        next.selectedMember = next.members.first
        next.testURL = testURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(next)
        dismiss()
    }
}
