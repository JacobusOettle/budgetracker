import SwiftUI
import SwiftData

/// Replace a belonging with a new one, or retire it without replacing.
struct ReplaceBelongingView: View {
    enum Mode: String, Identifiable {
        case replace, retire
        var id: String { rawValue }
    }

    let belonging: Belonging
    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var priceText = ""
    @State private var reason = ""
    @State private var paidFromSavings = true
    @State private var useCustom = false
    @State private var customMonths = 36
    @State private var errorMessage: String?

    private var newPriceCents: Int? { mode == .replace ? MoneyField.cents(priceText) : nil }

    private var lastedMonths: Int? {
        guard let current = belonging.currentOwnership else { return nil }
        return ReplacementPlanner.actualLifespanMonths(purchasedOn: current.purchasedOn, retiredOn: date)
    }

    private var settlement: ReplacementSettlement {
        ReplacementPlanner.settle(fundCents: belonging.fundBalanceCents, newPriceCents: newPriceCents)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(mode == .replace ? "Replaced on" : "Got rid of it on",
                               selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("Why? (optional, e.g. cracked screen)", text: $reason)
                    if let lastedMonths {
                        LabeledContent("It lasted", value: Lifespan.describe(months: lastedMonths))
                    }
                }

                if mode == .replace {
                    Section {
                        MoneyField(title: "New one cost", text: $priceText)
                        Toggle("Paid from savings", isOn: $paidFromSavings)
                    } footer: {
                        Text(paidFromSavings
                             ? "Your total savings balance goes down by the price."
                             : "Your total savings balance stays the same.")
                    }

                    Section {
                        Toggle("Set my own lifespan for the new one", isOn: $useCustom)
                        if useCustom {
                            LifespanEditor(months: $customMonths)
                        }
                    } footer: {
                        if let lastedMonths, !useCustom {
                            Text("The new one is expected to last \(Lifespan.describe(months: lastedMonths)), as long as this one did.")
                        }
                    }
                }

                Section("What happens to the fund") {
                    LabeledContent("Fund now", value: Money.format(cents: belonging.fundBalanceCents))
                    if mode == .replace {
                        LabeledContent("Pays for the new one", value: Money.format(cents: settlement.spentFromFundCents))
                    }
                    if settlement.releasedToTrueSavingsCents > 0 {
                        LabeledContent("Left over → true savings", value: Money.format(cents: settlement.releasedToTrueSavingsCents))
                            .foregroundStyle(.green)
                    }
                    if settlement.shortfallFromTrueSavingsCents > 0 {
                        LabeledContent("Short → from true savings", value: Money.format(cents: settlement.shortfallFromTrueSavingsCents))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(mode == .replace ? "Replace \(belonging.name)" : "Retire \(belonging.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { confirm() }
                        .disabled(mode == .replace && (newPriceCents ?? 0) <= 0)
                }
            }
            .onAppear {
                customMonths = belonging.lifespan()?.months ?? belonging.category.typicalLifespanMonths
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func confirm() {
        do {
            try FundService.replace(
                belonging,
                on: date,
                reason: reason.trimmingCharacters(in: .whitespaces),
                newPriceCents: newPriceCents,
                newCustomLifespanMonths: (mode == .replace && useCustom) ? customMonths : nil,
                paidFromSavings: paidFromSavings,
                in: context
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
