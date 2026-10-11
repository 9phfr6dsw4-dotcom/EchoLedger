import EchoLedgerCore
import SwiftUI

/// Questions about your money, answered on this Mac. Apple Intelligence only chooses which
/// read-only lookup to run; EchoLedger's report engine does every calculation.
struct AskView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @State private var question = ""

    private var intelligence: IntelligenceController { runtime.intelligence }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PageHeader(title: "Ask EchoLedger",
                                   subtitle: "Ask about your spending in plain words. Apple Intelligence looks up the answer with EchoLedger's own calculations, entirely on this Mac.")
                        if let reason = intelligence.unavailableReason {
                            GroupBox {
                                Label(reason, systemImage: "sparkles.slash")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            }
                        }
                        if intelligence.answers.isEmpty {
                            suggestions
                        }
                        ForEach(intelligence.answers) { answer in
                            AnswerCard(answer: answer)
                        }
                        if intelligence.isAnswering {
                            ProgressView("Looking it up…")
                        }
                        PrivacyFooter()
                            .id("bottom")
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: intelligence.answers.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Ask about your money…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .disabled(intelligence.isAnswering)
                Button("Ask", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || intelligence.isAnswering || !intelligence.isReady)
                if !intelligence.answers.isEmpty {
                    Button("Clear") { intelligence.answers.removeAll() }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var examples: [String] {
        var list = [
            "What changed in my spending last month?",
            "How much did we spend on dining in the last three months?",
            "What subscriptions do I have?",
            "What were the biggest purchases this month?"
        ]
        if let person = runtime.ledger.people.last {
            list.append("How much did \(person.name) spend at Amazon this year?")
        }
        return list
    }

    private var suggestions: some View {
        GroupBox("Try asking") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        question = example
                        send()
                    } label: {
                        Label(example, systemImage: "text.bubble")
                    }
                    .buttonStyle(.link)
                    .disabled(!intelligence.isReady)
                }
                Caption("Answers only use your imported transactions. Anything still waiting in Review is pointed out rather than guessed.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func send() {
        let text = question
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        question = ""
        Task { await intelligence.ask(text, runtime: runtime) }
    }
}

struct AnswerCard: View {
    let answer: AskAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(answer.question)
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(answer.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(answer.failed ? Color.secondary : Color.primary)
                    if !answer.isGrounded {
                        Label("Some numbers here don't match EchoLedger's calculations. Check the lookups below or the Reports screen.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !answer.lookups.isEmpty {
                        DisclosureGroup("How EchoLedger worked this out (\(answer.lookups.count) lookup\(answer.lookups.count == 1 ? "" : "s"))") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(answer.lookups) { entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(entry.tool): \(entry.arguments)")
                                            .font(.caption.weight(.semibold))
                                        Text(entry.result)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }
}
