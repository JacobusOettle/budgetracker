import SwiftUI
import SwiftData

/// Home: every budget's amount left. Tap one before paying to arm it.
struct BudgetsHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Budget.sortOrder) private var sortedBudgets: [Budget]
    private var budgets: [Budget] { sortedBudgets.filter { $0.archivedAt == nil } }
    @Query(sort: \Budget.createdAt) private var allBudgets: [Budget]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query private var closes: [MonthClose]

    @State private var showingNewBudget = false
    @State private var showingNewPayment = false
    @State private var editingBudget: Budget?
    @State private var viewingBudget: Budget?
    @State private var importingStatement = false
    @State private var showingSetup = false
    @State private var editMode: EditMode = .inactive
    @AppStorage("setupBanner.hidden") private var hideSetupBanner = false
    @State private var removingBudget: Budget?
    @State private var monthEnd: MonthTarget?
    @State private var errorMessage: String?

    init() {}

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                content(now: timeline.date)
            }
            .navigationTitle("Budgets")
            .task {
                // Payments the AI couldn't reach in the background get another try.
                await AutoCategorizer.categorizePending(in: context)
            }
            .navigationDestination(item: $viewingBudget) { budget in
                PaymentsListView(mode: .budget(budget))
                    .navigationTitle(budget.name)
            }
            .toolbar {
                if budgets.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Reorder") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New budget", systemImage: "plus") { showingNewBudget = true }
                        Button("Add a payment", systemImage: "square.and.pencil") { showingNewPayment = true }
                        Button("Import bank statement…", systemImage: "doc.text") { importingStatement = true }
                        Button("Month end…", systemImage: "calendar.badge.checkmark") {
                            monthEnd = MonthTarget(start: MonthMath.startOfMonth(.now))
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewBudget) { BudgetFormView(budget: nil) }
            .sheet(isPresented: $importingStatement) { StatementImportView() }
            .sheet(isPresented: $showingSetup) { NavigationStack { SetupGuideView() } }
            .sheet(item: $editingBudget) { BudgetFormView(budget: $0) }
            .sheet(isPresented: $showingNewPayment) { PaymentFormView(payment: nil) }
            .sheet(item: $monthEnd) { MonthEndView(month: $0.start) }
            .confirmationDialog(
                "Remove \(removingBudget?.name ?? "budget")?",
                isPresented: Binding(get: { removingBudget != nil }, set: { if !$0 { removingBudget = nil } }),
                titleVisibility: .visible,
                presenting: removingBudget
            ) { budget in
                Button("Remove", role: .destructive) {
                    perform { try BudgetService.remove(budget, in: context) }
                }
            } message: { budget in
                Text(budget.payments.isEmpty
                     ? "It has no payments and will be deleted."
                     : "Its payments stay in History under \(budget.name), and past months still add up.")
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let unassigned = payments.filter { $0.budget == nil }
        let review = payments.filter { $0.needsReview && $0.budget != nil }
        let unclosed = MonthEnd.unclosedMonths(
            firstUse: allBudgets.isEmpty ? nil : UsageStart.date(budgets: allBudgets, now: now),
            closedKeys: Set(closes.map(\.monthKey)),
            now: now
        )
        let automationWorking = payments.contains { $0.source == .shortcut }

        List {
            if !automationWorking && !hideSetupBanner {
                Section {
                    Button { showingSetup = true } label: {
                        Label("Set up automatic Apple Pay logging (about 1 minute)", systemImage: "wave.3.right")
                    }
                    Button("Not now", role: .cancel) { hideSetupBanner = true }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !unassigned.isEmpty || !review.isEmpty {
                Section {
                    NavigationLink {
                        PaymentsListView(mode: .needsAttention)
                            .navigationTitle("To sort out")
                    } label: {
                        Label(attentionText(unassigned: unassigned.count, review: review.count),
                              systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let month = unclosed.first {
                Section {
                    Button {
                        monthEnd = MonthTarget(start: month)
                    } label: {
                        Label("Close \(MonthMath.name(month)): move leftovers to savings",
                              systemImage: "calendar.badge.checkmark")
                    }
                }
            }

            if budgets.isEmpty {
                Section {
                    Text("Add budgets like Food, Fuel and Fun, each with a monthly amount, or let the AI set them up from a bank statement.")
                        .foregroundStyle(.secondary)
                    Button("Add your first budget") { showingNewBudget = true }
                    Button("Import a bank statement (PDF or CSV)…") { importingStatement = true }
                }
            } else {
                Section {
                    leftoverTotal(now: now)
                }

                Section {
                    ForEach(budgets) { budget in
                        let index = budgets.firstIndex { $0.id == budget.id } ?? 0
                        Button {
                            toggle(budget, now: now)
                        } label: {
                            BudgetCard(budget: budget, now: now)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Arming.isArmed(armedAt: budget.armedAt, now: now)
                                           ? Color.accentColor.opacity(0.18) : nil)
                        .contextMenu {
                            Button("Edit or recolour", systemImage: "paintpalette") { editingBudget = budget }
                            Button("Payments", systemImage: "list.bullet") { viewingBudget = budget }
                            if index > 0 {
                                Button("Move up", systemImage: "arrow.up") {
                                    perform { try BudgetService.move(budget, by: -1, in: context) }
                                }
                            }
                            if index < budgets.count - 1 {
                                Button("Move down", systemImage: "arrow.down") {
                                    perform { try BudgetService.move(budget, by: 1, in: context) }
                                }
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) { removingBudget = budget }
                        }
                        .sensoryFeedback(.impact, trigger: budget.armedAt)
                    }
                    .onMove { from, to in
                        perform { try BudgetService.move(fromOffsets: from, toOffset: to, in: context) }
                    }
                } footer: {
                    Text("Tap a budget just before you pay. The next payment in the following 10 minutes is logged to it. Tally can't block or change a payment. Long-press a budget to edit, recolour or move it.")
                }
            }
        }
        .environment(\.editMode, $editMode)
    }

    /// What's left across all budgets this month: what you could move to
    /// savings at month end if you spend nothing more. Same sum as Month End.
    private func leftoverTotal(now: Date) -> some View {
        let summary = MonthEnd.summary(budgets: allBudgets, payments: payments, month: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Left this month")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Money.format(cents: summary.toSaveCents))
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(summary.totalLeftCents < 0 ? Color.red : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(leftoverCaption(summary))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func leftoverCaption(_ summary: MonthEndSummary) -> String {
        if summary.totalLeftCents < 0 {
            return "You've spent \(Money.format(cents: -summary.totalLeftCents)) more than your budgets this month."
        }
        var text = "Across all your budgets: extra you can save at month end."
        if summary.unassignedCents > 0 {
            text += " After \(Money.format(cents: summary.unassignedCents)) of unassigned spending."
        }
        return text
    }

    private func attentionText(unassigned: Int, review: Int) -> String {
        var parts: [String] = []
        if unassigned > 0 { parts.append(unassigned == 1 ? "1 payment to assign" : "\(unassigned) payments to assign") }
        if review > 0 { parts.append(review == 1 ? "1 to check" : "\(review) to check") }
        return parts.joined(separator: ", ")
    }

    private func toggle(_ budget: Budget, now: Date) {
        perform {
            if Arming.isArmed(armedAt: budget.armedAt, now: now) {
                try BudgetService.disarm(budget, in: context)
            } else {
                try BudgetService.arm(budget, now: now, in: context)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

struct BudgetCard: View {
    let budget: Budget
    let now: Date

    var body: some View {
        let left = budget.leftCents(now: now)
        let remaining = Arming.remaining(armedAt: budget.armedAt, now: now)
        let armed = remaining > 0
        let warning = BudgetWarning.level(leftCents: left, monthlyCents: budget.monthlyCents)
        let color = Self.color(for: warning)

        let accent = BudgetPalette.color(for: budget)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent.gradient)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(budget.name).font(.headline)
                Spacer()
                if armed {
                    Label("Armed \(Arming.countdown(remaining))", systemImage: "bolt.fill")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(BudgetPalette.textOnFill(forKey: BudgetPalette.key(for: budget)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accent))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.format(cents: left))
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(color)
                Text("left of \(Money.format(cents: budget.monthlyCents))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: BudgetPalette.fill(leftCents: left, monthlyCents: budget.monthlyCents))
                .tint(warning == .none ? accent : color)
            if armed {
                Text(armedMessage(warning: warning, left: left))
                    .font(.footnote.weight(warning == .none ? .regular : .semibold))
                    .foregroundStyle(warning == .none ? Color.secondary : color)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    static func color(for warning: BudgetWarning) -> Color {
        switch warning {
        case .none: return .primary
        case .low: return .orange
        case .empty: return .red
        }
    }

    private func armedMessage(warning: BudgetWarning, left: Int) -> String {
        switch warning {
        case .none:
            return "Pay now. The next payment goes to \(budget.name). Tap again to disarm."
        case .low:
            return "Only \(Money.format(cents: left)) left. If you pay more, the payment still goes through: Tally can't stop it."
        case .empty:
            let state = left == 0 ? "is empty" : "is \(Money.format(cents: -left)) over budget"
            return "\(budget.name) \(state). The payment still goes through: Tally can't stop it."
        }
    }
}

struct BudgetFormView: View {
    let budget: Budget?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Budget.sortOrder) private var existingBudgets: [Budget]
    @State private var name: String
    @State private var amountText: String
    @State private var colorKey: String
    @State private var errorMessage: String?

    init(budget: Budget?) {
        self.budget = budget
        _name = State(initialValue: budget?.name ?? "")
        _amountText = State(initialValue: MoneyField.text(budget?.monthlyCents))
        _colorKey = State(initialValue: budget.map { BudgetPalette.key(for: $0) } ?? "")
    }

    private var cents: Int? { MoneyField.cents(amountText) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (cents ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Food", text: $name)
                    MoneyField(title: "Per month", text: $amountText)
                }
                Section("Colour") {
                    BudgetColorPicker(selection: $colorKey)
                }
                if let budget {
                    Section {
                        LabeledContent("Spent this month", value: Money.format(cents: budget.monthlyCents - budget.leftCents()))
                        LabeledContent("Left this month", value: Money.format(cents: budget.leftCents()))
                    } footer: {
                        Text("Changing the monthly amount applies to this month too.")
                    }
                }
            }
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
            .onAppear {
                if colorKey.isEmpty {
                    // A new budget gets the next unused colour.
                    let used = Set(existingBudgets.filter { $0.archivedAt == nil }.map { BudgetPalette.key(for: $0) })
                    colorKey = BudgetPalette.keys.first { !used.contains($0) } ?? BudgetPalette.keys[existingBudgets.count % BudgetPalette.keys.count]
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard let cents else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let budget {
                budget.name = trimmed
                budget.monthlyCents = cents
                budget.colorName = colorKey
                try context.save()
            } else {
                let new = try BudgetService.addBudget(name: trimmed, monthlyCents: cents, in: context)
                new.colorName = colorKey
                try context.save()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
