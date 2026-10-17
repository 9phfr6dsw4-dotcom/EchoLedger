import Charts
import EchoLedgerCore
import EchoLedgerPDF
import SwiftUI
import UniformTypeIdentifiers

enum ReportTab: String, CaseIterable, Identifiable {
    case overview, categories, merchants, trends, income, budgets, recurring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .categories: return "Categories"
        case .merchants: return "Merchants"
        case .trends: return "Trends"
        case .income: return "Income"
        case .budgets: return "Budgets"
        case .recurring: return "Recurring"
        }
    }
}

/// Everything one report screen shows, computed once from the same engine.
struct ReportBundle {
    let filter: ReportFilter
    let comparison: ReportComparison
    let recurring: [RecurringCharge]
    let unusual: [UnusualCharge]
    let facts: [ReportFact]

    var report: Report { comparison.current }

    init(ledger: Ledger, filter: ReportFilter, today: LocalDate) {
        self.filter = filter
        comparison = ReportComparison.build(ledger, filter: filter, today: today)
        recurring = Insights.recurring(ledger, filter: filter, asOf: min(filter.span.end, today))
        unusual = Insights.unusual(ledger, filter: filter)
        facts = ReportFacts.build(comparison: comparison, recurring: recurring, unusual: unusual)
    }
}

struct PDFExportRequest: Identifiable {
    let id = UUID()
    let bundle: ReportBundle
}

struct DrillDown: Identifiable {
    let id = UUID()
    let title: String
    let ids: [UUID]
}

struct ReportsView: View {
    @Environment(LedgerRuntime.self) private var runtime
    @State private var period: PeriodChoice = .lastMonth
    @State private var customStart = LocalDate(year: 2026, month: 1, day: 1) ?? LocalDate(dayNumber: 0)
    @State private var customEnd = LocalDate(year: 2026, month: 12, day: 31) ?? LocalDate(dayNumber: 0)
    @State private var people = PeopleSelection()
    @State private var tab: ReportTab = .overview
    @State private var drillDown: DrillDown?
    @State private var pdfReport: PDFExportRequest?

    private var filter: ReportFilter {
        let span = period.span(today: runtime.today, earliest: runtime.ledger.transactions.values.map(\.date).min(),
                               customStart: customStart, customEnd: customEnd)
        return people.filter(span: span, currency: runtime.ledger.settings.reportCurrency)
    }

    var body: some View {
        let bundle = ReportBundle(ledger: runtime.ledger, filter: filter, today: runtime.today)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: "Reports", subtitle: subtitle(bundle.report))
                    Spacer(minLength: 12)
                    if runtime.isDemo { Badge(text: "Demo data", color: Theme.accent) }
                }
                controls(bundle)
                content(bundle)
                DataNotesView(notes: bundle.report.notes)
            }
            .padding(32)
            .frame(maxWidth: 1500, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.canvas)
        .sheet(item: $pdfReport) { request in
            PDFExportSheet { style in exportPDF(request.bundle, style: style) }
        }
        .sheet(item: $drillDown) { item in
            DrillDownSheet(drillDown: item)
        }
    }

    private func subtitle(_ report: Report) -> String {
        let who = report.scopeLabel
        let accounts = report.accountNames.isEmpty ? "no accounts yet" : "\(report.accountNames.count) accounts"
        return "\(who) · \(accounts) · \(report.filter.currency) · \(DateText.medium(report.filter.span.start)) to \(DateText.medium(report.filter.span.end))"
    }

    private func controls(_ bundle: ReportBundle) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // When the window is too narrow for everything, the row scrolls sideways
            // instead of pushing the whole page wider than the window.
            ViewThatFits(in: .horizontal) {
                controlRow(bundle)
                ScrollView(.horizontal, showsIndicators: false) {
                    controlRow(bundle).padding(.bottom, 2)
                }
            }
            Picker("Report", selection: $tab) {
                ForEach(ReportTab.allCases) { tab in Text(tab.label).tag(tab) }
            }.pickerStyle(.segmented).labelsHidden()
        }
        .controlSize(.large)
        .padding(.bottom, 4)
    }

    private func controlRow(_ bundle: ReportBundle) -> some View {
        HStack(spacing: 10) {
            PeriodPicker(choice: $period, customStart: $customStart, customEnd: $customEnd)
            PeopleScopePicker(selection: $people)
            Spacer()
            Menu {
                Button("Report as PDF…") { pdfReport = PDFExportRequest(bundle: bundle) }
                Button("Report summary as CSV…") {
                    SavePanel.save(text: CSVExport.reportSummary(bundle.report),
                                   suggestedName: "EchoLedger \(bundle.report.filter.span.label).csv",
                                   type: .commaSeparatedText, runtime: runtime)
                }
                Button("Transactions in this report as CSV…") {
                    SavePanel.save(text: CSVExport.transactions(bundle.report.includedIDs, ledger: runtime.ledger),
                                   suggestedName: "EchoLedger \(bundle.report.filter.span.label) transactions.csv",
                                   type: .commaSeparatedText, runtime: runtime)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .frame(width: 110)
        }
    }

    private func exportPDF(_ bundle: ReportBundle, style: PDFReportStyle) {
        guard let url = SavePanel.choose(suggestedName: "EchoLedger \(bundle.report.filter.span.label).pdf", type: .pdf) else { return }
        let key = runtime.intelligence.narrativeKey(filter: bundle.filter, revision: runtime.revision)
        let bullets = runtime.intelligence.narratives[key] ?? []
        do {
            let content = PDFReportContent(report: bundle.report, ledger: runtime.ledger,
                                           summary: bullets.isEmpty ? bundle.facts.prefix(6).map(\.text) : bullets.map(\.text),
                                           summaryIsAI: !bullets.isEmpty, recurring: bundle.recurring)
            try ReportPDF.write(content: content, style: style, to: url)
            runtime.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            runtime.errorMessage = "Couldn't save the PDF: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func content(_ bundle: ReportBundle) -> some View {
        switch tab {
        case .overview: OverviewTab(bundle: bundle, drillDown: $drillDown)
        case .categories: CategoriesTab(bundle: bundle, drillDown: $drillDown)
        case .merchants: MerchantsTab(report: bundle.report, drillDown: $drillDown)
        case .trends: TrendsTab(filter: bundle.filter)
        case .income: IncomeTab(report: bundle.report, drillDown: $drillDown)
        case .budgets:
            if bundle.filter.wholeHousehold { BudgetsTab(report: bundle.report) }
            else {
                GroupBox("Household category budgets") {
                    Text("Choose Whole household to compare family category budgets with the family's spending. Personal allowances appear in the Overview for each person.")
                        .foregroundStyle(.secondary)
                }
            }
        case .recurring: RecurringTab(bundle: bundle, drillDown: $drillDown)
        }
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @Environment(LedgerRuntime.self) private var runtime
    let bundle: ReportBundle
    @Binding var drillDown: DrillDown?

    var body: some View {
        let report = bundle.report
        VStack(alignment: .leading, spacing: 24) {
            tiles(report)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    spendingChart.frame(minWidth: 330, maxWidth: .infinity)
                    categoryChart(report).frame(minWidth: 300, maxWidth: .infinity)
                }
                VStack(spacing: 18) { spendingChart; categoryChart(report) }
            }
            if !report.filter.wholeHousehold { householdContext(report) }
            SummaryCard(bundle: bundle, drillDown: $drillDown)
        }
    }

    private var spendingChart: some View {
        let end = bundle.filter.span.end
        let start = end.firstOfMonth.adding(months: -5)
        let report = ReportEngine.build(runtime.ledger, filter: bundle.filter.withSpan(DateSpan(start: start, end: end)), today: runtime.today)
        return GroupBox("Spending over time") {
            SpendingBars(months: report.months).frame(height: 225)
            Caption("Monthly spending · \(bundle.report.scopeLabel)")
        }
    }

    private func categoryChart(_ report: Report) -> some View {
        GroupBox("Where it went") {
            if report.categories.isEmpty {
                ContentUnavailableView("No spending yet", systemImage: "chart.bar", description: Text("Choose another period or import a bank file."))
                    .frame(height: 225)
            } else {
                VStack(spacing: 14) {
                    ForEach(report.categories.prefix(7)) { line in
                        Button {
                            drillDown = DrillDown(title: line.name, ids: line.transactionIDs)
                        } label: {
                            HStack(spacing: 12) {
                                Text(line.name).frame(width: 105, alignment: .leading).lineLimit(1)
                                GeometryReader { geometry in
                                    let maxAmount = max(1, report.categories.map(\.amount).max() ?? 1)
                                    Capsule().fill(Theme.accent.opacity(0.07))
                                    Capsule().fill(line.id == report.categories.first?.id ? Theme.accent : Theme.accentLight)
                                        .frame(width: geometry.size.width * CGFloat(max(0, line.amount)) / CGFloat(maxAmount))
                                }.frame(height: 14)
                                Text(Money.format(line.amount)).monospacedDigit().frame(width: 84, alignment: .trailing)
                            }.foregroundStyle(.primary).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.frame(minHeight: 225, alignment: .top).padding(.top, 5)
            }
        }
    }

    private func householdContext(_ report: Report) -> some View {
        let allFilter = ReportFilter(span: report.filter.span, currency: report.filter.currency)
        let household = ReportEngine.build(runtime.ledger, filter: allFilter, today: runtime.today)
        let share = Money.shareTenths(report.spending, of: household.spending)
        let budget = BudgetReport.lines(runtime.ledger, report: household).reduce(Cents(0)) { $0 + $1.budgeted }
        return GroupBox("Household context") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(share.map { Money.percentText(tenths: $0) + " of household spending" } ?? "No household spending in this period")
                        .font(.headline)
                    Caption("\(report.scopeLabel): \(Money.format(report.spending)) · Whole household: \(Money.format(household.spending))")
                }
                Spacer()
                if budget > 0 && BudgetReport.coversWholeMonths(report.filter.span) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Family category budgets: \(Money.format(budget))")
                        Caption("Whole household spending includes all people, shared, and unassigned transactions.")
                    }.frame(maxWidth: 350, alignment: .leading)
                }
            }
        }
    }

    private func tiles(_ report: Report) -> some View {
        let comparison = bundle.comparison
        let change = Money.changeTenthsOfPercent(from: comparison.previous.spending, to: report.spending)
        let spendingDetail = change.map { "\(Money.percentText(tenths: $0, showPlus: true)) vs previous period" } ?? "No earlier period to compare"
        let rate = report.savingsRateTenths.map { "\(Money.percentText(tenths: $0)) of income" } ?? "No income recorded"
        let selectedPerson = report.filter.personIDs.count == 1 && !report.filter.wholeHousehold && !report.filter.includeShared
            && !report.filter.includeUnassigned && report.filter.peopleMode == .assigned
            ? runtime.ledger.person(report.filter.personIDs.first) : nil
        let allowance = selectedPerson?.monthlyAllowance
        let wholeMonths = BudgetReport.coversWholeMonths(report.filter.span)
        let periodAllowance = allowance.flatMap { amount -> Cents? in
            let result = amount.multipliedReportingOverflow(by: Cents(report.filter.span.monthKeys.count))
            return result.overflow ? nil : result.partialValue
        }

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            MetricTile(title: "Income", value: Money.format(report.income), detail: "\(report.incomeSources.count) sources",
                       symbol: "arrow.down.circle", tint: Theme.income)
            MetricTile(title: "Spending", value: Money.format(report.spending), detail: spendingDetail,
                       symbol: "arrow.up.circle", tint: Theme.spending)
            MetricTile(title: "Net cash flow", value: Money.format(report.savings), detail: rate, symbol: "banknote", tint: Theme.accent)
            if wholeMonths, let periodAllowance {
                MetricTile(title: "Spending allowance", value: Money.format(periodAllowance), detail: "For the selected period", symbol: "wallet.bifold")
                MetricTile(title: "Allowance left", value: Money.format(periodAllowance - report.spending), detail: selectedPerson?.name, symbol: "checkmark.circle")
            }
        }
    }
}

/// The written summary: Apple Intelligence bullets that cite EchoLedger's facts, or the facts
/// themselves when AI isn't available.
struct SummaryCard: View {
    @Environment(LedgerRuntime.self) private var runtime
    let bundle: ReportBundle
    @Binding var drillDown: DrillDown?

    var body: some View {
        let intelligence = runtime.intelligence
        let key = intelligence.narrativeKey(filter: bundle.filter, revision: runtime.revision)
        let bullets = intelligence.narratives[key]
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(bullets == nil ? "Key facts" : "Summary", systemImage: bullets == nil ? "list.bullet" : "sparkles")
                        .font(.headline)
                    Spacer()
                    if intelligence.writingNarrative.contains(key) {
                        ProgressView().controlSize(.small)
                    } else if bullets == nil {
                        Button {
                            let facts = bundle.facts
                            Task { await intelligence.writeNarrative(key: key, facts: facts) }
                        } label: {
                            Label("Write Summary", systemImage: "sparkles")
                        }
                        .disabled(!intelligence.isReady || bundle.report.includedIDs.isEmpty)
                        .help(intelligence.unavailableReason ?? "Apple Intelligence writes a summary on this Mac from the numbers below.")
                    }
                }
                if let bullets {
                    ForEach(bullets) { bullet in
                        BulletRow(text: bullet.text, facts: bullet.facts, drillDown: $drillDown)
                    }
                    Caption("Written by Apple Intelligence on this Mac from EchoLedger's own figures. Every number was checked against the facts it cites.")
                } else {
                    if let failure = intelligence.narrativeFailures[key] {
                        Caption(failure)
                    }
                    ForEach(bundle.facts.prefix(6)) { fact in
                        BulletRow(text: fact.text, facts: [fact], drillDown: $drillDown)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct BulletRow: View {
    let text: String
    let facts: [ReportFact]
    @Binding var drillDown: DrillDown?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            let ids = facts.flatMap(\.transactionIDs)
            if !ids.isEmpty {
                Button("Show") {
                    drillDown = DrillDown(title: text, ids: ids)
                }
                .buttonStyle(.link)
                .help(facts.map { "\($0.id): \($0.text)" }.joined(separator: "\n"))
            }
        }
    }
}

struct CategoryDonut: View {
    let categories: [CategoryLine]

    var body: some View {
        Chart(categories.filter { $0.amount > 0 }) { line in
            SectorMark(angle: .value("Spent", Theme.dollars(line.amount)), innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(Theme.color(forCategoryIndex: line.colorIndex))
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
    }
}

struct CategoryLegend: View {
    let report: Report
    @Binding var drillDown: DrillDown?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(report.categories) { line in
                Button {
                    drillDown = DrillDown(title: line.name, ids: line.transactionIDs)
                } label: {
                    HStack {
                        CategoryDot(colorIndex: line.colorIndex)
                        Text(line.name)
                        Spacer()
                        Text(Money.shareTenths(line.amount, of: report.spending).map { Money.percentText(tenths: $0) } ?? "")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                        Text(Money.format(line.amount))
                            .monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Text("Total spending").fontWeight(.semibold)
                Spacer()
                Text(Money.format(report.spending))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            if report.refunds > 0 {
                Caption("After \(Money.format(report.refunds)) in refunds. Transfers and card payments (\(Money.format(report.transferVolume)) moved between accounts) aren't spending.")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct MonthBars: View {
    let months: [MonthLine]

    var body: some View {
        Chart {
            ForEach(months) { month in
                BarMark(x: .value("Month", DateText.monthLabel(month.monthKey)), y: .value("Amount", Theme.dollars(month.income)))
                    .foregroundStyle(by: .value("Type", "Income"))
                    .position(by: .value("Type", "Income"))
                BarMark(x: .value("Month", DateText.monthLabel(month.monthKey)), y: .value("Amount", Theme.dollars(month.spending)))
                    .foregroundStyle(by: .value("Type", "Spending"))
                    .position(by: .value("Type", "Spending"))
            }
        }
        .chartForegroundStyleScale(["Income": Theme.income, "Spending": Theme.spending])
        .chartXAxis { ReportMonthAxis() }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(Money.formatWhole(Cents(dollars * 100)))
                    }
                }
            }
        }
    }
}

// MARK: - Categories

struct CategoriesTab: View {
    let bundle: ReportBundle
    @Binding var drillDown: DrillDown?

    var body: some View {
        let report = bundle.report
        VStack(alignment: .leading, spacing: 20) {
            if !report.categories.isEmpty {
                GroupBox("Spending by category") {
                    CategoryBars(categories: report.categories)
                        .frame(height: CGFloat(max(160, report.categories.count * 30)))
                        .padding(.vertical, 8)
                }
            }
            GroupBox("Compared with \(bundle.comparison.previous.filter.span.label)") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Category").frame(maxWidth: .infinity, alignment: .leading)
                        Text("This period").frame(width: 110, alignment: .trailing)
                        Text("Before").frame(width: 110, alignment: .trailing)
                        Text("Change").frame(width: 120, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    ForEach(bundle.comparison.categoryChanges) { change in
                        CategoryComparisonRow(change: change, line: report.categories.first { $0.id == change.id }, drillDown: $drillDown)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct CategoryBars: View {
    let categories: [CategoryLine]

    var body: some View {
        Chart(categories) { line in
            BarMark(x: .value("Spent", Theme.dollars(line.amount)), y: .value("Category", line.name))
                .foregroundStyle(Theme.color(forCategoryIndex: line.colorIndex))
                .annotation(position: .trailing) {
                    Text(Money.formatWhole(line.amount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
    }
}

struct CategoryComparisonRow: View {
    let change: CategoryChange
    let line: CategoryLine?
    @Binding var drillDown: DrillDown?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        CategoryDot(colorIndex: line?.colorIndex ?? -1)
                        Text(change.name)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Money.format(change.current)).monospacedDigit().frame(width: 110, alignment: .trailing)
                Text(Money.format(change.previous)).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                Text(changeText)
                    .monospacedDigit()
                    .foregroundStyle(change.change > 0 ? Theme.spending : (change.change < 0 ? Theme.income : Color.secondary))
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.vertical, 6)
            if expanded, let line {
                ForEach(line.merchants) { merchant in
                    Button {
                        drillDown = DrillDown(title: "\(merchant.name) · \(line.name)", ids: merchant.transactionIDs)
                    } label: {
                        HStack {
                            Text(merchant.name).padding(.leading, 34)
                            Text("\(merchant.count)×").foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.format(merchant.amount)).monospacedDigit()
                                .frame(width: 110, alignment: .trailing)
                            Spacer().frame(width: 230)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var changeText: String {
        let amount = Money.format(change.change, showPlus: true)
        guard let tenths = change.changeTenths else { return amount }
        return "\(amount) (\(Money.percentText(tenths: tenths, showPlus: true)))"
    }
}

// MARK: - Merchants

struct MerchantsTab: View {
    let report: Report
    @Binding var drillDown: DrillDown?

    var body: some View {
        GroupBox("Where the money went") {
            VStack(alignment: .leading, spacing: 8) {
                if report.topMerchants.isEmpty {
                    Caption("No spending in this period.")
                }
                ForEach(report.topMerchants) { merchant in
                    Button {
                        drillDown = DrillDown(title: merchant.name, ids: merchant.transactionIDs)
                    } label: {
                        HStack {
                            Text(merchant.name).lineLimit(1)
                            Text("\(merchant.count) transaction\(merchant.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            ShareBar(fraction: report.spending > 0 ? Double(max(merchant.amount, 0)) / Double(report.spending) : 0)
                                .frame(minWidth: 30, maxWidth: 140)
                                .frame(height: 8)
                            Text(Money.format(merchant.amount))
                                .monospacedDigit()
                                .frame(width: 110, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                Caption("Top 15 merchants by spending, after refunds. Payment services such as PayPal are shown as the business behind them when the bank text says.")
            }
            .padding(.vertical, 4)
        }
    }
}

struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Theme.accent)
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
    }
}

// MARK: - Trends

struct TrendsTab: View {
    @Environment(LedgerRuntime.self) private var runtime
    let filter: ReportFilter

    var body: some View {
        let end = filter.span.end.lastOfMonth
        let span = DateSpan(start: end.firstOfMonth.adding(months: -11), end: end)
        let report = ReportEngine.build(runtime.ledger, filter: filter.withSpan(span), today: runtime.today)
        let averageSpending = report.months.isEmpty ? 0 : report.spending / Int64(report.months.count)
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Twelve months to \(DateText.monthLabel(end.monthKey))") {
                MonthBars(months: report.months)
                    .frame(height: 260)
                    .padding(.vertical, 8)
            }
            GroupBox("By month") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Month").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Income").frame(width: 120, alignment: .trailing)
                        Text("Spending").frame(width: 120, alignment: .trailing)
                        Text("Saved").frame(width: 120, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    ForEach(report.months.reversed()) { month in
                        HStack {
                            Text(DateText.monthLabel(month.monthKey)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(Money.format(month.income)).monospacedDigit().frame(width: 120, alignment: .trailing)
                            Text(Money.format(month.spending)).monospacedDigit().frame(width: 120, alignment: .trailing)
                            Text(Money.format(month.net)).monospacedDigit()
                                .foregroundStyle(month.net >= 0 ? Theme.income : Theme.spending)
                                .frame(width: 120, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                    Caption("Average monthly spending over these 12 months: \(Money.format(averageSpending)). Months before your first import show as zero.")
                        .padding(.top, 6)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Income

struct IncomeTab: View {
    let report: Report
    @Binding var drillDown: DrillDown?

    var body: some View {
        GroupBox("Income sources") {
            VStack(alignment: .leading, spacing: 8) {
                if report.incomeSources.isEmpty {
                    Caption("No income in this period. Paychecks are recognized automatically; other deposits wait in Review until you say what they are.")
                }
                ForEach(report.incomeSources) { source in
                    Button {
                        drillDown = DrillDown(title: source.name, ids: source.transactionIDs)
                    } label: {
                        HStack {
                            Text(source.name)
                            Text("\(source.count)×").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.shareTenths(source.amount, of: report.income).map { Money.percentText(tenths: $0) } ?? "")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(Money.format(source.amount))
                                .monospacedDigit()
                                .frame(width: 120, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                HStack {
                    Text("Total income").fontWeight(.semibold)
                    Spacer()
                    Text(Money.format(report.income)).fontWeight(.semibold).monospacedDigit()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Budgets

struct BudgetsTab: View {
    @Environment(LedgerRuntime.self) private var runtime
    let report: Report

    var body: some View {
        let lines = BudgetReport.lines(runtime.ledger, report: report)
        let months = report.filter.span.monthKeys.count
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Budget vs actual") {
                VStack(alignment: .leading, spacing: 12) {
                    if lines.isEmpty {
                        Caption("No budgets yet. Set monthly amounts below.")
                    }
                    ForEach(lines) { line in
                        BudgetRow(line: line)
                    }
                    if !BudgetReport.coversWholeMonths(report.filter.span) {
                        Caption("This period doesn't cover whole months, so budgets count each month it touches in full.")
                    } else if months > 1 {
                        Caption("Budgets are monthly; this period covers \(months) months, so each budget is multiplied by \(months).")
                    }
                }
                .padding(.vertical, 4)
            }
            GroupBox("Monthly budgets") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(runtime.ledger.categories.filter { $0.group == .expense }) { category in
                        BudgetEditorRow(category: category)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct BudgetRow: View {
    let line: BudgetLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CategoryDot(colorIndex: line.colorIndex)
                Text(line.name)
                Spacer()
                Text("\(Money.format(line.spent)) of \(Money.format(line.budgeted))")
                    .monospacedDigit()
                Text(line.isOver ? "\(Money.format(-line.remaining)) over" : "\(Money.format(line.remaining)) left")
                    .foregroundStyle(line.isOver ? Theme.spending : Theme.income)
                    .monospacedDigit()
                    .frame(width: 120, alignment: .trailing)
            }
            ProgressView(value: min(Double(max(line.spent, 0)), Double(line.budgeted)), total: Double(max(line.budgeted, 1)))
                .tint(line.isOver ? Theme.spending : Theme.color(forCategoryIndex: line.colorIndex))
        }
    }
}

struct BudgetEditorRow: View {
    @Environment(LedgerRuntime.self) private var runtime
    let category: LedgerCategory
    @State private var text = ""

    var body: some View {
        HStack {
            CategoryDot(colorIndex: category.colorIndex)
            Text(category.name)
            Spacer()
            TextField("No budget", text: $text)
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
                .onSubmit(save)
            Text("per month")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if let budget = runtime.ledger.budgets.first(where: { $0.categoryID == category.id }) {
                text = Money.decimalString(budget.monthlyAmount)
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let id = category.id
        if trimmed.isEmpty {
            runtime.commit { $0.setBudget(categoryID: id, monthlyAmount: nil) }
            return
        }
        guard let cents = Money.parseCents(trimmed), cents >= 0 else {
            runtime.errorMessage = "“\(trimmed)” isn't an amount. Use a number like 250 or 250.00."
            return
        }
        runtime.commit { $0.setBudget(categoryID: id, monthlyAmount: cents) }
        text = Money.decimalString(cents)
    }
}

// MARK: - Recurring

struct RecurringTab: View {
    let bundle: ReportBundle
    @Binding var drillDown: DrillDown?

    var body: some View {
        let active = bundle.recurring.filter(\.isActive)
        let ended = bundle.recurring.filter { !$0.isActive }
        let monthly = active.reduce(Cents(0)) { total, charge in
            switch charge.cadence {
            case .monthly: return total + charge.typicalAmount
            case .weekly: return total + charge.typicalAmount * 52 / 12
            case .yearly: return total + charge.typicalAmount / 12
            }
        }
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Recurring charges") {
                VStack(alignment: .leading, spacing: 8) {
                    if active.isEmpty {
                        Caption("None found yet. A charge counts as recurring after at least three similar charges on a regular schedule.")
                    } else {
                        Text("About \(Money.format(monthly)) a month across \(active.count) active charges")
                            .font(.headline)
                    }
                    ForEach(active) { charge in
                        RecurringRow(charge: charge, drillDown: $drillDown)
                        Divider()
                    }
                    if !ended.isEmpty {
                        DisclosureGroup("Stopped (\(ended.count))") {
                            ForEach(ended) { charge in
                                RecurringRow(charge: charge, drillDown: $drillDown)
                            }
                        }
                    }
                    Caption("Found by arithmetic on your transactions (no AI): regular gaps between charges and steady amounts.")
                }
                .padding(.vertical, 4)
            }
            GroupBox("Unusual this period") {
                VStack(alignment: .leading, spacing: 8) {
                    if bundle.unusual.isEmpty {
                        Caption("Nothing stands out: no charge was at least three times its merchant's usual amount, and no first-time charge was over $200.")
                    }
                    ForEach(bundle.unusual) { item in
                        Button {
                            drillDown = DrillDown(title: item.merchantName, ids: [item.transactionID])
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.merchantName) · \(DateText.medium(item.date))")
                                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Money.format(item.amount)).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct RecurringRow: View {
    let charge: RecurringCharge
    @Binding var drillDown: DrillDown?

    var body: some View {
        Button {
            drillDown = DrillDown(title: charge.merchantName, ids: charge.transactionIDs)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(charge.merchantName)
                        if charge.priceChanged {
                            Badge(text: "Price changed", color: .orange)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.format(charge.typicalAmount)).monospacedDigit()
                    Text("\(Money.format(charge.yearlyCost)) a year").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        var text = "\(charge.cadence.label) · last \(DateText.medium(charge.lastDate))"
        if charge.isActive { text += " · next around \(DateText.medium(charge.nextExpected))" }
        if charge.priceChanged {
            text += " · was \(Money.format(charge.previousAmount)), now \(Money.format(charge.lastAmount))"
        }
        return text
    }
}

// MARK: - Drill-down

struct DrillDownSheet: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let drillDown: DrillDown

    var body: some View {
        let transactions = drillDown.ids.compactMap { runtime.ledger.transactions[$0] }
            .sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
        let total = transactions.reduce(Cents(0)) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 14) {
            Text(drillDown.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            Text("\(transactions.count) transactions · net \(Money.format(total))")
                .foregroundStyle(.secondary)
            List(transactions) { transaction in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ReportEngine.merchantIdentity(transaction, ledger: runtime.ledger).name)
                        Text("\(DateText.medium(transaction.date)) · \(transaction.rawDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    MoneyText(cents: transaction.amount)
                }
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button("Open in Transactions") {
                    runtime.showTransactions(TransactionsFocus(title: drillDown.title, ids: Set(drillDown.ids)))
                    dismiss()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 640, minHeight: 340, idealHeight: 520)
    }
}


struct SpendingBars: View {
    let months: [MonthLine]
    var body: some View {
        Chart(months) { month in
            BarMark(x: .value("Month", DateText.monthLabel(month.monthKey)), y: .value("Spending", Theme.dollars(month.spending)))
                .foregroundStyle(month.id == months.last?.id ? Theme.accent : Theme.accentLight)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text(Money.formatWhole(month.spending)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis { ReportMonthAxis() }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let dollars = value.as(Double.self) { Text(Money.formatWhole(Cents(dollars * 100))) }
                }
            }
        }
        .chartPlotStyle { $0.padding(.top, 14) }
    }
}

/// Keep month names outside the plot, below zero-value bars and their amount annotations.
struct ReportMonthAxis: AxisContent {
    var body: some AxisContent {
        AxisMarks(preset: .aligned, position: .bottom) {
            AxisGridLine().foregroundStyle(.primary.opacity(0.06))
            AxisTick()
            AxisValueLabel(anchor: .top, verticalSpacing: 8)
        }
    }
}
