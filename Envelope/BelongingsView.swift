import SwiftUI
import SwiftData

/// Things you own, what you set aside each month to replace them, and how
/// your savings split between replacement funds and true savings.
struct BelongingsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Belonging> { $0.archived == false }, sort: \Belonging.name)
    private var belongings: [Belonging]
    @Query(filter: #Predicate<Belonging> { $0.archived == true }, sort: \Belonging.name)
    private var retired: [Belonging]
    @Query private var accounts: [SavingsAccount]

    @State private var showingAdd = false
    @State private var editingSavings = false
    @State private var savingsText = ""
    @State private var confirmingContributions = false
    @State private var errorMessage: String?

    var body: some View {
        let today = Date()
        let total = SavingsAccount.effectiveBalance(accounts)
        let setAside = (belongings + retired).reduce(0) { $0 + $1.fundBalanceCents }
        let trueSavings = SavingsSplit.trueSavings(totalCents: total, setAsideCents: setAside)
        let monthly = belongings.compactMap { $0.plan(today: today)?.monthlyCents }.reduce(0, +)
        let pending = FundService.pendingContributions(belongings: belongings, month: today)
        let pendingTotal = pending.reduce(0) { $0 + $1.cents }
        let monthName = today.formatted(.dateTime.month(.wide))

        NavigationStack {
            List {
                Section {
                    Button {
                        savingsText = MoneyField.text(total)
                        editingSavings = true
                    } label: {
                        LabeledContent("Total in savings", value: Money.format(cents: total))
                    }
                    .foregroundStyle(.primary)
                    LabeledContent("Set aside for replacements", value: Money.format(cents: setAside))
                    LabeledContent("True savings") {
                        Text(Money.format(cents: trueSavings))
                            .bold()
                            .foregroundStyle(trueSavings < 0 ? .red : .primary)
                    }
                } header: {
                    Text("Savings")
                } footer: {
                    if trueSavings < 0 {
                        Text("Your savings balance is less than what's set aside for replacements. Update the balance, or some replacement funds aren't really there.")
                    } else {
                        Text("Tap Total in savings to update it from your banking app. Spaar can't see your bank.")
                    }
                }

                Section {
                    LabeledContent("Set aside each month", value: Money.format(cents: monthly))
                    if pendingTotal > 0 {
                        Button("Record \(monthName) contributions (\(Money.format(cents: pendingTotal)))") {
                            confirmingContributions = true
                        }
                    } else if !belongings.isEmpty {
                        Label("\(monthName) contributions recorded", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Replacement funds")
                } footer: {
                    Text("Move this amount into savings each month. When something lasts longer than expected, contributions stop and the rest of what you save is true savings.")
                }

                Section("Belongings") {
                    if belongings.isEmpty {
                        Text("Add your phone, laptop, fridge, tyres… to see what to set aside for each.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(belongings) { belonging in
                        NavigationLink {
                            BelongingDetailView(belonging: belonging)
                        } label: {
                            BelongingRow(belonging: belonging, today: today)
                        }
                    }
                }

                if !retired.isEmpty {
                    Section("Retired") {
                        ForEach(retired) { belonging in
                            NavigationLink {
                                BelongingDetailView(belonging: belonging)
                            } label: {
                                Label(belonging.name, systemImage: belonging.category.systemImage)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Belongings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Label("Add", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                BelongingFormView(belonging: nil)
            }
            .alert("Total in savings", isPresented: $editingSavings) {
                TextField("Amount", text: $savingsText).keyboardType(.decimalPad)
                Button("Save") {
                    guard let cents = MoneyField.cents(savingsText) else { return }
                    perform { try FundService.setSavingsBalance(cents, in: context) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your savings account balance in rand, as it shows in your banking app.")
            }
            .confirmationDialog(
                "Record \(Money.format(cents: pendingTotal)) for \(monthName)?",
                isPresented: $confirmingContributions,
                titleVisibility: .visible
            ) {
                Button("I moved it to savings. Add it to my balance") {
                    perform { _ = try FundService.recordContributions(belongings: belongings, month: Date(), addToSavingsBalance: true, in: context) }
                }
                Button("It's already in my savings balance") {
                    perform { _ = try FundService.recordContributions(belongings: belongings, month: Date(), addToSavingsBalance: false, in: context) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Spaar can't move money. Do the transfer in your banking app, then confirm here.")
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

private struct BelongingRow: View {
    let belonging: Belonging
    let today: Date

    var body: some View {
        if let plan = belonging.plan(today: today) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(belonging.name, systemImage: belonging.category.systemImage)
                        .font(.headline)
                    Spacer()
                    Text(plan.monthlyCents > 0 ? "\(Money.format(cents: plan.monthlyCents))/mo" : statusText(plan))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(plan.status == .due ? .red : .primary)
                }
                ProgressView(value: progress(plan))
                    .tint(plan.status == .due ? .red : .accentColor)
                Text("\(Money.format(cents: plan.savedCents)) of \(Money.format(cents: plan.targetCents)) · replace ~\(plan.expectedReplacementDate.formatted(.dateTime.month(.abbreviated).year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            Label(belonging.name, systemImage: belonging.category.systemImage)
        }
    }

    private func progress(_ plan: ReplacementPlan) -> Double {
        guard plan.targetCents > 0 else { return 1 }
        return min(1, max(0, Double(plan.savedCents) / Double(plan.targetCents)))  // display only
    }

    private func statusText(_ plan: ReplacementPlan) -> String {
        switch plan.status {
        case .funded: "Funded"
        case .due: "Short \(Money.format(cents: plan.shortfallCents))"
        case .saving: ""
        }
    }
}
