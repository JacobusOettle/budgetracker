import SwiftUI
import SwiftData

/// Month end: what's left per budget, the total to move to savings, and how
/// it splits between replacement funds and true savings.
struct MonthEndView: View {
    let month: Date

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var budgets: [Budget]
    @Query private var payments: [Payment]
    @Query private var closes: [MonthClose]
    @Query(filter: #Predicate<Belonging> { $0.archived == false }) private var belongings: [Belonging]

    @State private var movedText = ""
    @State private var didPrefill = false
    @State private var errorMessage: String?

    init(month: Date) {
        self.month = month
    }

    private var monthName: String { MonthMath.name(month) }
    private var key: String { ReplacementPlanner.monthKey(for: month) }
    private var existing: MonthClose? { closes.first { $0.monthKey == key } }

    var body: some View {
        let summary = MonthEnd.summary(budgets: budgets, payments: payments, month: month)
        let replacement = FundService.pendingContributions(belongings: belongings, month: month).reduce(0) { $0 + $1.cents }
        let moved = MoneyField.cents(movedText)

        NavigationStack {
            Form {
                if let existing {
                    Section {
                        Label("Closed on \(existing.closedAt.formatted(date: .abbreviated, time: .omitted)). You moved \(Money.format(cents: existing.movedCents)) to savings.",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section("Left over per budget") {
                    if summary.lines.isEmpty {
                        Text("No budgets this month.").foregroundStyle(.secondary)
                    }
                    ForEach(summary.lines, id: \.name) { line in
                        LabeledContent(line.name) {
                            Text(Money.format(cents: line.leftCents))
                                .monospacedDigit()
                                .foregroundStyle(line.leftCents < 0 ? Color.red : Color.primary)
                        }
                    }
                    if summary.unassignedCount > 0 {
                        LabeledContent("Unassigned payments (\(summary.unassignedCount))") {
                            Text(Money.format(cents: -summary.unassignedCents))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    LabeledContent("Total to move to savings") {
                        Text(Money.format(cents: summary.toSaveCents)).bold().monospacedDigit()
                    }
                    if replacement > 0 {
                        LabeledContent("For replacement funds", value: Money.format(cents: replacement))
                        LabeledContent("True savings", value: Money.format(cents: max(0, summary.toSaveCents - replacement)))
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if summary.unassignedCount > 0 {
                            Text("Assign the unassigned payments first to see accurate leftovers per budget. They're already taken off the total.")
                        }
                        if summary.totalLeftCents < 0 {
                            Text("You spent \(Money.format(cents: -summary.totalLeftCents)) more than your budgets this month.")
                        }
                        if replacement > summary.toSaveCents {
                            Text("Your leftover doesn't cover this month's replacement funds (\(Money.format(cents: replacement))). The difference comes out of true savings.")
                        }
                    }
                }

                if existing == nil {
                    Section {
                        MoneyField(title: "I moved", text: $movedText)
                        Button("I've moved it. Close \(monthName)") {
                            close(summary: summary, moved: moved ?? 0)
                        }
                        .disabled(moved == nil)
                    } footer: {
                        Text("Envelope can't move money. Transfer it to savings in your banking app first, then confirm here. Your savings balance goes up by this amount, and budgets start fresh with the new month.")
                    }
                }
            }
            .navigationTitle(monthName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                movedText = MoneyField.text(summary.toSaveCents)
            }
            .alert("Couldn't close the month", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func close(summary: MonthEndSummary, moved: Int) {
        do {
            try BudgetService.closeMonth(month, summary: summary, movedCents: moved, belongings: belongings, in: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
