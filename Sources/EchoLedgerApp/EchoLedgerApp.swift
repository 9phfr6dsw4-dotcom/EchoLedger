import AppKit
import EchoLedgerCore
import SwiftUI

@main
@MainActor
struct EchoLedgerApp: App {
    @State private var runtime = LedgerRuntime()

    var body: some Scene {
        WindowGroup("EchoLedger") {
            RootView()
                .environment(runtime)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { runtime.section = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Import Bank Files…") {
                    runtime.section = .importFiles
                    runtime.importer.requestFilePicker = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .undoRedo) {
                Button(runtime.undoLabel.map { "Undo \($0)" } ?? "Undo Last Change") { runtime.undo() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(runtime.undoLabel == nil)
            }
            CommandMenu("Go") {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) { runtime.section = section }
                        .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command)
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(LedgerRuntime.self) private var runtime

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: sectionSelection) {
                    ForEach(AppSection.allCases) { section in
                        sidebarRow(section)
                            .tag(section)
                    }
                }
                IntelligenceStatusBadge()
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // Messages float over the page so showing or hiding one never resizes the screen.
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if let message = runtime.errorMessage {
                            MessageBar(text: message, isError: true) { runtime.errorMessage = nil }
                        }
                        if let message = runtime.statusMessage {
                            MessageBar(text: message, isError: false) { runtime.statusMessage = nil }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 720)
                }
        }
        .navigationTitle(runtime.section.title)
        .task(id: runtime.statusMessage) {
            guard runtime.statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            runtime.statusMessage = nil
        }
    }

    private var sectionSelection: Binding<AppSection?> {
        Binding(get: { runtime.section }, set: { value in
            if let value { runtime.section = value }
        })
    }

    @ViewBuilder
    private func sidebarRow(_ section: AppSection) -> some View {
        let count = section == .review ? runtime.ledger.reviewCount + runtime.ledger.aiFiledUnchecked.count : 0
        if count > 0 {
            Label(section.title, systemImage: section.symbol)
                .badge(count)
        } else {
            Label(section.title, systemImage: section.symbol)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch runtime.section {
        case .importFiles: ImportView()
        case .review: ReviewView()
        case .transactions: TransactionsView()
        case .reports: ReportsView()
        case .ask: AskView()
        case .rules: RulesView()
        case .settings: SettingsView()
        }
    }
}

struct MessageBar: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Theme.income)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(isError ? Color.red.opacity(0.18) : Theme.income.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}
