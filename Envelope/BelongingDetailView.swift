import SwiftUI
import SwiftData

struct BelongingDetailView: View {
    let belonging: Belonging

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var replaceMode: ReplaceBelongingView.Mode?
    @State private var adjustingFund = false
    @State private var fundText = ""
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let plan = belonging.plan() {
                Section("Plan") {
                    LabeledContent("Expected to last", value: Lifespan.describe(months: plan.lifespan.months))
                    Text("Based on \(plan.lifespan.sourceDescription).")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Replace around", value: plan.expectedReplacementDate.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Saving towards", value: Money.format(cents: plan.targetCents))
                    LabeledContent("Saved so far", value: Money.format(cents: plan.savedCents))
                    LabeledContent("Set aside per month") {
                        Text(Money.format(cents: plan.monthlyCents)).bold()
                    }
                    if plan.status == .saving {
                        LabeledContent("Contributions left", value: "\(plan.remainingMonths)")
                    }
                    Text(statusMessage(plan))
                        .font(.footnote)
                        .foregroundStyle(plan.status == .due ? .red : .secondary)
                }
            } else {
                Section {
                    Text("Retired without a replacement. Its fund was moved to true savings.")
                        .foregroundStyle(.secondary)
                }
            }

            if !belonging.archived {
                Section {
                    Button("Replace it…") { replaceMode = .replace }
                    Button("Got rid of it, not replacing…") { replaceMode = .retire }
                    Button("Edit details") { editing = true }
                    Button("Correct saved amount") {
                        fundText = MoneyField.text(belonging.fundBalanceCents)
                        adjustingFund = true
                    }
                }
            }

            Section("Owned") {
                ForEach(belonging.sortedOwnerships) { o in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(o.purchasedOn.formatted(date: .abbreviated, time: .omitted)) · \(Money.format(cents: o.priceCents))")
                        if let retiredOn = o.retiredOn {
                            let months = ReplacementPlanner.actualLifespanMonths(purchasedOn: o.purchasedOn, retiredOn: retiredOn)
                            Text(lastedText(months: months, reason: o.retiredReason))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Current").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Fund history") {
                if belonging.fundEntries.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(belonging.sortedFundEntries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.kind.displayName)
                            Text(entry.monthKey ?? entry.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(cents: entry.cents)).monospacedDigit()
                    }
                }
            }

            Section {
                Button("Delete", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Deleting removes its history too. Use \"Got rid of it\" to keep the record.")
            }
        }
        .navigationTitle(belonging.name)
        .sheet(isPresented: $editing) { BelongingFormView(belonging: belonging) }
        .sheet(item: $replaceMode) { mode in ReplaceBelongingView(belonging: belonging, mode: mode) }
        .alert("Saved so far", isPresented: $adjustingFund) {
            TextField("Amount", text: $fundText).keyboardType(.decimalPad)
            Button("Save") {
                guard let cents = MoneyField.cents(fundText) else { return }
                do { try FundService.setFundBalance(belonging, to: cents, in: context) } catch { errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How much is really set aside for \(belonging.name)? This adds an adjustment to its history.")
        }
        .confirmationDialog("Delete \(belonging.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(belonging)
                try? context.save()
                dismiss()
            }
        } message: {
            Text("Its fund of \(Money.format(cents: belonging.fundBalanceCents)) stops being set aside and counts as true savings.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func lastedText(months: Int, reason: String?) -> String {
        let lasted = "Lasted " + Lifespan.describe(months: months)
        guard let reason, !reason.isEmpty else { return lasted }
        return lasted + " · " + reason
    }

    private func statusMessage(_ plan: ReplacementPlan) -> String {
        switch plan.status {
        case .saving:
            return "On track if you set aside \(Money.format(cents: plan.monthlyCents)) each month."
        case .funded:
            return plan.isPastExpectedLife
                ? "It's outlasted its expected life and is fully funded. Nothing more to set aside: what you save from now on is true savings."
                : "Fully funded. Nothing more to set aside for it."
        case .due:
            return "It's reached its expected life and the fund is short by \(Money.format(cents: plan.shortfallCents)). If it breaks, use true savings or buy a cheaper one. While it keeps working, nothing more is set aside."
        }
    }
}
