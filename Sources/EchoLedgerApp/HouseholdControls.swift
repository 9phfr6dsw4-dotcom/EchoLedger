import EchoLedgerCore
import SwiftUI

struct PeopleSelection: Equatable {
    var wholeHousehold = true
    var people: Set<UUID> = []
    var shared = false
    var unassigned = false
    var mode: PeopleMode = .assigned

    func filter(span: DateSpan, currency: String) -> ReportFilter {
        ReportFilter(span: span, personIDs: people, currency: currency,
                     wholeHousehold: wholeHousehold, includeShared: shared, includeUnassigned: unassigned,
                     peopleMode: mode)
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
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .leading)
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
                Text("Count").font(.headline)
                Picker("Count", selection: $draft.mode) {
                    Text("Spending assigned to them").tag(PeopleMode.assigned)
                    Text("Everything on their cards").tag(PeopleMode.cards)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(draft.wholeHousehold)
                Caption(draft.mode == .assigned
                        ? "Follows who each purchase was assigned to, including single purchases you reassigned."
                        : "Includes every purchase on a card they use, even ones you reassigned to someone else.")
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

/// Who uses an account or card. Everyone belongs to the household; pick the people who use it
/// (one, several, or no one in particular).
struct CardUsersMenu: View {
    @Environment(LedgerRuntime.self) private var runtime
    let account: Account
    let onChange: (Account) -> Void

    var body: some View {
        Menu {
            ForEach(runtime.ledger.people) { person in
                Toggle(person.name, isOn: Binding(
                    get: { account.userIDs.contains(person.id) },
                    set: { value in
                        var copy = account
                        if value {
                            if !copy.userIDs.contains(person.id) { copy.userIDs.append(person.id) }
                        } else {
                            copy.userIDs.removeAll { $0 == person.id }
                        }
                        copy.isUnassigned = false
                        onChange(copy)
                    }))
            }
            Divider()
            Button("Household card, no one in particular") {
                var copy = account
                copy.defaultAssignment = .shared
                onChange(copy)
            }
            Button("Not decided yet (unassigned)") {
                var copy = account
                copy.defaultAssignment = .unassigned
                onChange(copy)
            }
        } label: {
            Text(runtime.ledger.usersLabel(account)).lineLimit(1)
        }
    }
}
