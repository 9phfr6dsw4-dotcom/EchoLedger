import EchoLedgerPDF
import SwiftUI

/// Selection precedes the save panel; cancellation never starts an export.
struct PDFExportSheet: View {
    @Environment(LedgerRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var style: PDFReportStyle = .signature
    let export: (PDFReportStyle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose a report style").font(.title2.weight(.semibold))
            Text("All three styles include the same figures, selected people or cards, and report notes.")
                .foregroundStyle(.secondary)
            ForEach(PDFReportStyle.allCases) { option in
                Button {
                    style = option
                } label: {
                    HStack(spacing: 14) {
                        PDFStyleSwatch(style: option).frame(width: 62, height: 76)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(option.name).font(.headline)
                            Text(option.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: style == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(style == option ? Theme.accent : Color.secondary)
                    }
                    .padding(12)
                    .background(style == option ? Theme.accent.opacity(0.07) : Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(style == option ? Theme.accent : Color.secondary.opacity(0.2)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.name). \(option.detail)")
                .accessibilityAddTraits(style == option ? [.isSelected] : [])
            }
            HStack {
                Text("Letter size · Multiple pages as needed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save PDF…") {
                    runtime.defaults.set(style.rawValue, forKey: "EchoLedger.pdfReportStyle")
                    dismiss()
                    // Present the save panel after the style sheet has been dismissed.
                    DispatchQueue.main.async { export(style) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            style = PDFReportStyle(rawValue: runtime.defaults.string(forKey: "EchoLedger.pdfReportStyle") ?? "") ?? .signature
        }
    }
}

private struct PDFStyleSwatch: View {
    let style: PDFReportStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if style == .everyday { Rectangle().fill(Theme.accent).frame(height: 9) }
            Text(style == .precision ? "REPORT" : "Report")
                .font(style == .signature ? .system(size: 11, weight: .semibold, design: .serif) : .system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent)
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: style == .everyday ? 2 : 0).fill(Theme.accent.opacity(0.15)).frame(height: 9) }
            }
            ForEach(0..<3) { index in
                HStack(spacing: 3) {
                    Rectangle().fill(Theme.accent.opacity(0.15)).frame(width: 12, height: 2)
                    Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: CGFloat(24 - index * 5), height: 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(style == .signature ? Color(red: 0.993, green: 0.989, blue: 0.976) : .white)
        .overlay(Rectangle().stroke(Color.gray.opacity(0.25)))
        .accessibilityHidden(true)
    }
}
