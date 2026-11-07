import SwiftUI
import SwiftData

/// Add a belonging (belonging == nil) or edit an existing one.
struct BelongingFormView: View {
    let belonging: Belonging?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var category: BelongingCategory
    @State private var purchasedOn: Date
    @State private var priceText: String
    @State private var nextPriceText: String
    @State private var alreadySavedText: String
    @State private var ownedBefore: Bool
    @State private var previousMonths: Int
    @State private var useCustom: Bool
    @State private var customMonths: Int
    @State private var errorMessage: String?

    init(belonging: Belonging?) {
        self.belonging = belonging
        let current = belonging?.currentOwnership
        let category = belonging?.category ?? .phone
        _name = State(initialValue: belonging?.name ?? "")
        _category = State(initialValue: category)
        _purchasedOn = State(initialValue: current?.purchasedOn ?? .now)
        _priceText = State(initialValue: MoneyField.text(current?.priceCents))
        _nextPriceText = State(initialValue: MoneyField.text(current?.replacementCostCents))
        _alreadySavedText = State(initialValue: "")
        _ownedBefore = State(initialValue: belonging?.previousLifespanMonths != nil)
        _previousMonths = State(initialValue: belonging?.previousLifespanMonths ?? category.typicalLifespanMonths)
        _useCustom = State(initialValue: current?.customLifespanMonths != nil)
        _customMonths = State(initialValue: current?.customLifespanMonths ?? category.typicalLifespanMonths)
    }

    private var isEditing: Bool { belonging != nil }
    private var priceCents: Int? { MoneyField.cents(priceText) }
    private var nextPriceCents: Int? { nextPriceText.isEmpty ? nil : MoneyField.cents(nextPriceText) }
    private var alreadySavedCents: Int { MoneyField.cents(alreadySavedText) ?? 0 }

    private var lifespan: Lifespan {
        ReplacementPlanner.resolveLifespan(
            customMonths: useCustom ? customMonths : nil,
            previousMonths: ownedBefore ? previousMonths : nil,
            category: category
        )
    }

    private var previewPlan: ReplacementPlan? {
        guard let priceCents, lifespan.months > 0 else { return nil }
        let today = Date()
        let saved = belonging?.fundBalanceCents ?? alreadySavedCents
        let contributed = belonging?.hasContribution(forMonthKey: ReplacementPlanner.monthKey(for: today)) ?? false
        return ReplacementPlanner.plan(
            purchasedOn: purchasedOn,
            targetCents: nextPriceCents ?? priceCents,
            savedCents: saved,
            lifespan: lifespan,
            contributedThisMonth: contributed,
            today: today
        )
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (priceCents ?? 0) > 0
            && lifespan.months > 0
            && (nextPriceText.isEmpty || nextPriceCents != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. iPhone 15", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(BelongingCategory.allCases) { c in
                            Label(c.displayName, systemImage: c.systemImage).tag(c)
                        }
                    }
                }

                Section {
                    DatePicker("Bought on", selection: $purchasedOn, in: ...Date(), displayedComponents: .date)
                    MoneyField(title: "Price paid", text: $priceText)
                    MoneyField(title: "Next one will cost", text: $nextPriceText)
                    if !isEditing {
                        MoneyField(title: "Already saved for it", text: $alreadySavedText)
                    }
                } footer: {
                    Text("Leave \"Next one will cost\" empty to save towards the price you paid.")
                }

                Section {
                    Toggle("I've owned one before", isOn: $ownedBefore)
                    if ownedBefore {
                        Text("How long did the last one last?").font(.subheadline)
                        LifespanEditor(months: $previousMonths)
                    }
                } footer: {
                    Text("If you have, Spaar expects this one to last as long as the last one did.")
                }

                Section {
                    Toggle("Set my own lifespan", isOn: $useCustom)
                    if useCustom {
                        LifespanEditor(months: $customMonths)
                    }
                } header: {
                    Text("How long will it last?")
                } footer: {
                    Text("Typical for \(category.displayName.lowercased()): \(Lifespan.describe(months: category.typicalLifespanMonths)). That's a rough built-in estimate, not real data about you.")
                }

                if let plan = previewPlan {
                    Section("Plan") {
                        LabeledContent("Expected to last", value: Lifespan.describe(months: plan.lifespan.months))
                        Text("Based on \(plan.lifespan.sourceDescription).")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Replace around", value: plan.expectedReplacementDate.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Set aside per month") {
                            Text(Money.format(cents: plan.monthlyCents)).bold()
                        }
                        if plan.status == .due {
                            Text("It's already past its expected life and the fund is short by \(Money.format(cents: plan.shortfallCents)).")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit" : "Add belonging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onChange(of: category) { _, newValue in
                if !useCustom { customMonths = newValue.typicalLifespanMonths }
                if !ownedBefore { previousMonths = newValue.typicalLifespanMonths }
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard let priceCents else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let belonging {
                belonging.name = trimmed
                belonging.category = category
                belonging.previousLifespanMonths = ownedBefore ? previousMonths : nil
                if let current = belonging.currentOwnership {
                    current.purchasedOn = purchasedOn
                    current.priceCents = priceCents
                    current.replacementCostCents = nextPriceCents
                    current.customLifespanMonths = useCustom ? customMonths : nil
                }
                try context.save()
            } else {
                try FundService.addBelonging(
                    name: trimmed,
                    category: category,
                    purchasedOn: purchasedOn,
                    priceCents: priceCents,
                    replacementCostCents: nextPriceCents,
                    customLifespanMonths: useCustom ? customMonths : nil,
                    previousLifespanMonths: ownedBefore ? previousMonths : nil,
                    alreadySavedCents: alreadySavedCents,
                    in: context
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
