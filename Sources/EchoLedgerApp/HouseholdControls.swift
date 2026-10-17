import EchoLedgerCore
import SwiftUI

struct PeopleSelection: Equatable {
    var wholeHousehold = true
    var people: Set<UUID> = []
    var shared = false
    var unassigned = false

    func filter(span: DateSpan, currency: String) -> ReportFilter {
        ReportFilter(span: span, personIDs: people, currency: currency,
                     wholeHousehold: wholeHousehold, includeShared: shared, includeUnassigned: unassigned)
    }
    var isEmpty: Bool { !wholeHousehold && people.isEmpty && !shared && !unassigned }
}

struct PeopleScopePicker: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Binding var selection: PeopleSelection
    @State private var showing = false
    @State private var draft = PeopleSelection()

    var body: some View {
        Button {
            draft = selection
            showing = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                Text(selection.filter(span: .month(containing: runtime.today), currency: "USD").scopeLabel(in: runtime.ledger))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .controlSize(.large)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("People").font(.headline)
                Button("Whole household") { draft = PeopleSelection() }
                    .buttonStyle(.borderless)
                if draft.wholeHousehold { Caption("Everyone, shared spending, and unassigned transactions") }
                Divider()
                ForEach(runtime.ledger.people) { person in
                    Toggle(person.name, isOn: Binding(
                        get: { !draft.wholeHousehold && draft.people.contains(person.id) },
                        set: { value in
                            draft.wholeHousehold = false
                            if value { draft.people.insert(person.id) } else { draft.people.remove(person.id) }
                        }))
                }
                Divider()
                Toggle("Shared household", isOn: groupBinding(\.shared))
                Toggle("Unassigned", isOn: groupBinding(\.unassigned))
                Divider()
                HStack {
                    Caption("Choose one or more")
                    Spacer()
                    Button("Apply") { selection = draft; showing = false }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.isEmpty)
                }
            }
            .toggleStyle(.checkbox)
            .padding(20)
            .frame(width: 290)
        }
    }

    private func groupBinding(_ key: WritableKeyPath<PeopleSelection, Bool>) -> Binding<Bool> {
        Binding(get: { !draft.wholeHousehold && draft[keyPath: key] }, set: { value in
            draft.wholeHousehold = false
            draft[keyPath: key] = value
        })
    }
}

struct AssignmentPicker: View {
    @Environment(LedgerRuntime.self) private var runtime
    var title = "Assign spending to"
    @Binding var assignment: SpendingAssignment

    var body: some View {
        Picker(title, selection: $assignment) {
            ForEach(runtime.ledger.people) { person in Text(person.name).tag(SpendingAssignment.person(person.id)) }
            Text("Shared household").tag(SpendingAssignment.shared)
            Text("Unassigned").tag(SpendingAssignment.unassigned)
        }
    }
}
