import EchoLedgerCore
import Foundation
import Observation
import SwiftUI

/// One answer from "Ask EchoLedger".
struct AskAnswer: Identifiable {
    let id = UUID()
    let question: String
    var text: String
    var lookups: [ToolCallLog.Entry]
    /// False when a number in the answer doesn't match EchoLedger's own calculations.
    var isGrounded: Bool
    var failed: Bool
}

/// What Apple Intelligence made of a file EchoLedger didn't recognize.
struct LayoutOutcome {
    /// The checked layout, when the model's answer could be turned into one.
    var check: LayoutCheck?
    var message: String
}

/// Apple Intelligence's explanation of one charge.
struct ChargeExplanation {
    var text: String
    var isConfident: Bool
    /// False when the explanation mentions a number that isn't part of the charge.
    var isGrounded: Bool
    var failed: Bool
}

/// Everything EchoLedger does with Apple Intelligence, all on this Mac. Every answer is checked
/// before it's used, filings are marked so you can check them, everything is undoable, and all of
/// it can be turned off in Settings.
@MainActor
@Observable
final class IntelligenceController {
    nonisolated static let enabledKey = "EchoLedger.aiEnabled"
    /// Look at new transactions after each import.
    nonisolated static let autoSuggestKey = "EchoLedger.aiAutoSuggest"
    /// File what it can (on), or only suggest (off).
    nonisolated static let autoFileKey = "EchoLedger.aiAutoFile"
    nonisolated static let tidyNamesKey = "EchoLedger.aiTidyNames"
    nonisolated static let setUpLayoutsKey = "EchoLedger.aiSetUpLayouts"

    /// The most groups looked at in one go.
    static let maxGroups = 100

    private(set) var isSuggesting = false
    private(set) var suggestionProgress = ""
    private(set) var workingGroupIDs: Set<String> = []
    private(set) var isTidying = false
    private(set) var narratives: [String: [GroundedBullet]] = [:]
    private(set) var narrativeFailures: [String: String] = [:]
    private(set) var writingNarrative: Set<String> = []
    private(set) var explanations: [UUID: ChargeExplanation] = [:]
    private(set) var explaining: Set<UUID> = []
    var answers: [AskAnswer] = []
    private(set) var isAnswering = false
    private var lookTask: Task<Void, Never>?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    var isEnabled: Bool { flag(Self.enabledKey) }
    var autoSuggest: Bool { flag(Self.autoSuggestKey) }
    var autoFile: Bool { flag(Self.autoFileKey) }
    var tidyNames: Bool { flag(Self.tidyNamesKey) }
    var setUpLayouts: Bool { flag(Self.setUpLayoutsKey) }

    /// nil when AI features can run; otherwise why not.
    var unavailableReason: String? {
        if !isEnabled { return "Apple Intelligence features are turned off in Settings." }
        return OnDeviceModel.unavailableReason
    }

    var isReady: Bool { unavailableReason == nil }

    func invalidate() {
        narratives.removeAll()
        narrativeFailures.removeAll()
    }

    // MARK: Filing new transactions

    /// After an import: look at everything EchoLedger couldn't place, then tidy merchant names.
    func afterImport(runtime: LedgerRuntime) {
        guard isReady, autoSuggest else { return }
        let groups = ReviewQueue.groups(runtime.ledger).filter { $0.suggestion?.source != .ai }
        lookTask = Task {
            if !groups.isEmpty { await self.lookAt(groups, runtime: runtime) }
            if self.tidyNames, !Task.isCancelled { await self.tidyMerchantNames(runtime: runtime) }
        }
    }

    func start(_ groups: [ReviewGroup], runtime: LedgerRuntime) {
        guard !isSuggesting else { return }
        lookTask = Task { await self.lookAt(groups, runtime: runtime) }
    }

    /// Stops after the current question. What was already decided is still saved.
    func stop() {
        lookTask?.cancel()
    }

    /// Asks the on-device model about each group (at most `maxGroups`). With auto-filing on,
    /// every answer that passes EchoLedger's checks is filed and marked "Filed by Apple
    /// Intelligence" (one undoable change for the whole run); otherwise, and for bank text you
    /// corrected before, it's stored as a suggestion for you to approve.
    func lookAt(_ groups: [ReviewGroup], runtime: LedgerRuntime) async {
        guard isReady, !isSuggesting else { return }
        isSuggesting = true
        defer {
            isSuggesting = false
            suggestionProgress = ""
            workingGroupIDs.removeAll()
        }
        let batch = Array(groups.prefix(Self.maxGroups))
        let fileThem = autoFile
        let rejected = runtime.ledger.rejectedAIKeys
        var requests: [Ledger.AIFilingRequest] = []
        var suggested = 0
        for (index, group) in batch.enumerated() {
            if Task.isCancelled { break }
            suggestionProgress = "Apple Intelligence is looking at \(index + 1) of \(batch.count)…"
            workingGroupIDs = [group.id]
            let ledger = runtime.ledger
            guard let first = group.transactionIDs.first.flatMap({ ledger.transactions[$0] }),
                  let suggestion = await guess(first, group: group, ledger: ledger) else { continue }
            if fileThem, !group.key.isEmpty, !rejected.contains(group.key) {
                requests.append(Ledger.AIFilingRequest(ids: group.transactionIDs, key: group.key, merchantName: suggestion.merchantName,
                                                       kind: suggestion.kind, categoryID: suggestion.categoryID,
                                                       reason: suggestion.reason))
            } else {
                let categoryName = runtime.ledger.category(suggestion.categoryID)?.name ?? suggestion.kind.label
                let evidence = "Apple Intelligence suggests \(suggestion.merchantName ?? "an unknown merchant") (\(categoryName)). Check before approving."
                let ids = group.transactionIDs
                runtime.commit { $0.setSuggestion(suggestion, evidence: evidence, for: ids) }
                suggested += 1
            }
        }
        var filed = 0
        if !requests.isEmpty {
            let pending = requests
            let before = runtime.ledger.aiFiledUnchecked.count
            runtime.commit { $0.fileByAI(pending) }
            filed = max(0, runtime.ledger.aiFiledUnchecked.count - before)
        }
        var parts: [String] = []
        if filed > 0 {
            parts.append("Apple Intelligence filed \(filed) transaction\(filed == 1 ? "" : "s"). They're marked so you can check them in Review, and Undo reverses the whole run.")
        }
        if suggested > 0 {
            parts.append("It suggested merchants for \(suggested) group\(suggested == 1 ? "" : "s"); approve them in Review.")
        }
        if !parts.isEmpty { runtime.statusMessage = parts.joined(separator: " ") }
    }

    /// One checked answer from the model, or nil when it abstained, failed, or answered something
    /// that doesn't fit (an unknown category, income that's money out, a name that isn't a name).
    private func guess(_ transaction: LedgerTransaction, group: ReviewGroup, ledger: Ledger) async -> Suggestion? {
        let prompt = merchantPrompt(transaction, group: group, ledger: ledger)
        do {
            let guess = try await OnDeviceModel.guessMerchant(prompt)
            guard var suggestion = SuggestionCheck.validate(merchant: guess.merchant, category: guess.category, kind: guess.kind,
                                                             ledger: ledger, amount: transaction.amount) else { return nil }
            suggestion.reason = guess.reason.isEmpty ? "Apple Intelligence's best match." : guess.reason
            return suggestion
        } catch {
            return nil
        }
    }

    private func merchantPrompt(_ transaction: LedgerTransaction, group: ReviewGroup, ledger: Ledger) -> String {
        let expenseNames = ledger.categories.filter { $0.group == .expense }.map(\.name).joined(separator: ", ")
        let incomeNames = ledger.categories.filter { $0.group == .income }.map(\.name).joined(separator: ", ")
        var lines = ["Identify this transaction.", SuggestionCheck.describe(transaction, ledger: ledger), "Times seen: \(group.count)"]
        if let hint = group.suggestion, hint.source != .ai {
            let category = ledger.category(hint.categoryID)?.name ?? hint.kind.label
            lines.append("EchoLedger's own guess (may be wrong): \(hint.merchantName ?? "unknown merchant"), \(category). \(hint.reason)")
        }
        let examples = StyleExamples.examples(for: transaction, ledger: ledger)
        if !examples.isEmpty {
            lines.append("How this person filed similar transactions:")
            lines.append(contentsOf: examples.map { "- " + $0 })
        }
        lines.append("Allowed expense categories: \(expenseNames)")
        lines.append("Allowed income categories: \(incomeNames)")
        lines.append("For a transfer between the person's own accounts, use kind transfer and category none.")
        return lines.joined(separator: "\n")
    }

    // MARK: Merchant names

    /// Gives merchants whose names still look like bank text a proper name. Names you set
    /// yourself are never changed, and a proposed name must plainly be the same business.
    func tidyMerchantNames(runtime: LedgerRuntime) async {
        guard isReady, !isTidying else { return }
        let directory = Set(BuiltInKnowledge.merchants.map { $0.name.lowercased() })
        let candidates = runtime.ledger.merchants.values
            .filter { MerchantNames.needsTidying($0, directoryNames: directory) }
            .sorted { $0.name < $1.name }
            .prefix(40)
        guard !candidates.isEmpty else { return }
        isTidying = true
        defer { isTidying = false }
        var renames: [(id: UUID, name: String)] = []
        for merchant in candidates {
            if Task.isCancelled { break }
            let bankText = merchant.keys.first ?? merchant.name
            let prompt = "Current name: \(merchant.name)\nBank text: \(SuggestionCheck.redactDigits(bankText))\nGive the merchant's tidy name."
            guard let proposed = try? await OnDeviceModel.tidyName(prompt),
                  let accepted = MerchantNames.acceptRename(from: merchant.name, to: proposed) else { continue }
            renames.append((id: merchant.id, name: accepted))
        }
        guard !renames.isEmpty else { return }
        let final = renames
        let before = runtime.ledger.changes.count
        runtime.commit { $0.tidyMerchantNames(final) }
        if runtime.ledger.changes.count > before {
            runtime.statusMessage = "Apple Intelligence tidied merchant names. Undo puts them back."
        }
    }

    // MARK: New bank layouts

    var canSetUpLayouts: Bool { isReady && setUpLayouts }

    /// Asks the model which column is which in a file EchoLedger doesn't recognize, then reads the
    /// whole file with that layout to prove it. Only the first rows (long numbers hidden) are shown
    /// to the model.
    func proposeLayout(fileName: String, data: Data) async -> LayoutOutcome {
        let rows = LayoutProposal.sampleRows(data)
        guard rows.count >= 2 else {
            return LayoutOutcome(check: nil, message: "The file is too short for Apple Intelligence to work out its columns.")
        }
        let prompt = "First rows of the file:\n\(LayoutProposal.promptText(rows))\n\nWhich column holds what?"
        do {
            let guess = try await OnDeviceModel.proposeLayout(prompt)
            let id = "custom-" + String(UUID().uuidString.prefix(8)).lowercased()
            guard let profile = LayoutProposal.makeProfile(guess, rows: rows, id: id) else {
                return LayoutOutcome(check: nil, message: "Apple Intelligence's reading of the columns didn't fit this file.")
            }
            let check = await Task.detached(priority: .userInitiated) {
                LayoutProposal.check(profile, fileName: fileName, data: data)
            }.value
            return LayoutOutcome(check: check, message: check.note)
        } catch is ModelTimeout {
            return LayoutOutcome(check: nil, message: "Apple Intelligence took too long to read this file.")
        } catch {
            return LayoutOutcome(check: nil, message: "Apple Intelligence couldn't read this file (\(error.localizedDescription)).")
        }
    }

    // MARK: What is this charge?

    func explain(_ transaction: LedgerTransaction, runtime: LedgerRuntime) async {
        let id = transaction.id
        guard isReady, !explaining.contains(id) else { return }
        explaining.insert(id)
        defer { explaining.remove(id) }
        let facts = explanationFacts(transaction, ledger: runtime.ledger)
        do {
            let result = try await OnDeviceModel.explain("Explain this charge.\n\(facts)")
            let grounded = Grounding.isGrounded(result.text, sources: [facts])
            explanations[id] = ChargeExplanation(text: result.text, isConfident: result.isConfident && grounded,
                                                 isGrounded: grounded, failed: false)
        } catch is ModelTimeout {
            explanations[id] = ChargeExplanation(text: "Apple Intelligence took too long. Try again.", isConfident: false,
                                                 isGrounded: true, failed: true)
        } catch {
            explanations[id] = ChargeExplanation(text: "Apple Intelligence couldn't explain this charge (\(error.localizedDescription)).",
                                                 isConfident: false, isGrounded: true, failed: true)
        }
    }

    /// The facts about a charge the model may use: the bank's text (long numbers hidden), how it
    /// was filed, and how often the same bank text appears.
    private func explanationFacts(_ transaction: LedgerTransaction, ledger: Ledger) -> String {
        var lines = [SuggestionCheck.describe(transaction, ledger: ledger), "Date: \(DateText.medium(transaction.date))"]
        let key = MerchantText(transaction.rawDescription).key
        let same = ledger.transactions.values.filter { $0.isActive && !key.isEmpty && MerchantText($0.rawDescription).key == key }
        if same.count > 1, let first = same.map(\.date).min() {
            lines.append("The same bank text appears \(same.count) times, first on \(DateText.medium(first)).")
        }
        if let merchant = ledger.merchant(transaction.merchantID) { lines.append("Filed under merchant: \(merchant.name)") }
        if let category = ledger.category(transaction.categoryID) { lines.append("Filed in category: \(category.name)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Report summaries

    func narrativeKey(filter: ReportFilter, revision: Int) -> String {
        "\(filter.wholeHousehold)|\(filter.peopleMode.rawValue)|\(filter.includeShared)|\(filter.includeUnassigned)|\(filter.currency)|\(revision)|\(filter.span.start.iso)|\(filter.span.end.iso)|\(filter.personIDs.map(\.uuidString).sorted().joined(separator: ","))|\(filter.accountIDs.map(\.uuidString).sorted().joined(separator: ","))"
    }

    /// Writes a short summary from EchoLedger's computed facts. Bullets that cite no fact, or use a
    /// number that isn't in the facts they cite, are dropped.
    func writeNarrative(key: String, facts: [ReportFact]) async {
        guard isReady, !writingNarrative.contains(key) else { return }
        writingNarrative.insert(key)
        defer { writingNarrative.remove(key) }
        let list = facts.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
        let prompt = "Facts:\n\(list)\n\nWrite three to five bullets about what stands out. Use only these facts."
        do {
            let drafts = try await OnDeviceModel.writeNarrative(prompt)
            let kept = Grounding.checkBullets(drafts, facts: facts)
            if kept.isEmpty {
                narrativeFailures[key] = "Apple Intelligence's summary didn't match the numbers, so it isn't shown. The key facts are below."
            } else {
                narratives[key] = kept
                narrativeFailures[key] = nil
            }
        } catch is ModelTimeout {
            narrativeFailures[key] = "Apple Intelligence took too long. Try again."
        } catch {
            narrativeFailures[key] = "Apple Intelligence couldn't write a summary (\(error.localizedDescription))."
        }
    }

    // MARK: Ask

    func ask(_ question: String, runtime: LedgerRuntime) async {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isAnswering else { return }
        guard isReady else {
            answers.append(AskAnswer(question: clean, text: unavailableReason ?? "Apple Intelligence isn't available.",
                                     lookups: [], isGrounded: true, failed: true))
            return
        }
        isAnswering = true
        defer { isAnswering = false }
        let log = ToolCallLog()
        let snapshot = runtime.ledger
        let today = runtime.today
        let tools = AskTools.all(ledger: snapshot, today: today, log: log)
        let instructions = OnDeviceModel.assistantInstructions(context: FinanceQueries.context(snapshot, today: today))
        do {
            let text = try await OnDeviceModel.answer(clean, instructions: instructions, tools: tools)
            let lookups = log.entries
            // Every number must come from a lookup; an answer with numbers but no lookups is unverified.
            let hasNumbers = !Grounding.numbers(in: text).isEmpty
            let grounded = !hasNumbers || (!lookups.isEmpty && Grounding.isGrounded(text, sources: lookups.map(\.result)))
            answers.append(AskAnswer(question: clean, text: text, lookups: lookups, isGrounded: grounded, failed: false))
        } catch is ModelTimeout {
            answers.append(AskAnswer(question: clean, text: "Apple Intelligence took too long to answer. Try a simpler question.",
                                     lookups: log.entries, isGrounded: true, failed: true))
        } catch {
            answers.append(AskAnswer(question: clean, text: "Apple Intelligence couldn't answer that (\(error.localizedDescription)).",
                                     lookups: log.entries, isGrounded: true, failed: true))
        }
    }
}

/// Shows whether Apple Intelligence is ready, in the sidebar.
struct IntelligenceStatusBadge: View {
    @Environment(LedgerRuntime.self) private var runtime

    var body: some View {
        let reason = runtime.intelligence.unavailableReason
        HStack(spacing: 6) {
            Image(systemName: reason == nil ? "sparkles" : "sparkles.slash")
                .foregroundStyle(reason == nil ? Theme.accent : Color.secondary)
            Text(reason == nil ? "Apple Intelligence on this Mac" : "Apple Intelligence off")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .help(reason ?? "On-device only. Nothing is sent anywhere.")
    }
}
