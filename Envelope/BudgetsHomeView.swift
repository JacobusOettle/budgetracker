import SwiftUI
import SwiftData

/// Home: every budget's amount left. Tap one before paying to arm it.
struct BudgetsHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Budget> { $0.archivedAt == nil },
           sort: [SortDescriptor(\Budget.sortOrder), SortDescriptor(\Budget.name)])
    private var budgets: [Budget]
    @Query(sort: \Budget.createdAt) private var allBudgets: [Budget]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query private var closes: [MonthClose]

    @State private var showingNewBudget = false
    @State private var showingNewPayment = false
    @State private var editingBudget: Budget?
    @State private var viewingBudget: Budget?
    @State private var removingBudget: Budget?
    @State private var monthEnd: MonthTarget?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                content(now: timeline.date)
            }
            .navigationTitle("Budgets")
            .navigationDestination(item: $viewingBudget) { budget in
                PaymentsListView(mode: .budget(budget))
                    .navigationTitle(budget.name)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New budget", systemImage: "plus") { showingNewBudget = true }
                        Button("Add a payment", systemImage: "square.and.pencil") { showingNewPayment = true }
                        Button("Month end…", systemImage: "calendar.badge.checkmark") {
                            monthEnd = MonthTarget(start: MonthMath.startOfMonth(.now))
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewBudget) { BudgetFormView(budget: nil) }
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
            firstUse: allBudgets.first?.createdAt,
            closedKeys: Set(closes.map(\.monthKey)),
            now: now
        )

        List {
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
                    Text("Add budgets like Food, Fuel and Fun, each with a monthly amount.")
                        .foregroundStyle(.secondary)
                    Button("Add your first budget") { showingNewBudget = true }
                }
            } else {
                Section {
                    ForEach(budgets) { budget in
                        Button {
                            toggle(budget, now: now)
                        } label: {
                            BudgetCard(budget: budget, now: now)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Arming.isArmed(armedAt: budget.armedAt, now: now)
                                           ? Color.accentColor.opacity(0.18) : nil)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editingBudget = budget }
                            Button("Payments", systemImage: "list.bullet") { viewingBudget = budget }
                            Button("Remove", systemImage: "trash", role: .destructive) { removingBudget = budget }
                        }
                        .sensoryFeedback(.impact, trigger: budget.armedAt)
                    }
                } footer: {
                    Text("Tap a budget just before you pay. The next payment in the following 10 minutes is logged to it. Envelope can't block or change a payment. Long-press a budget to edit it.")
                }
            }
        }
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

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(budget.name).font(.headline)
                Spacer()
                if armed {
                    Label("Armed \(Arming.countdown(remaining))", systemImage: "bolt.fill")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
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
            ProgressView(value: fractionLeft(left))
                .tint(warning == .none ? Color.accentColor : color)
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

    private func fractionLeft(_ left: Int) -> Double {
        guard budget.monthlyCents > 0 else { return 0 }
        return min(1, max(0, Double(left) / Double(budget.monthlyCents)))  // display only
    }

    private func armedMessage(warning: BudgetWarning, left: Int) -> String {
        switch warning {
        case .none:
            return "Pay now. The next payment goes to \(budget.name). Tap again to disarm."
        case .low:
            return "Only \(Money.format(cents: left)) left. If you pay more, the payment still goes through: Envelope can't stop it."
        case .empty:
            let state = left == 0 ? "is empty" : "is \(Money.format(cents: -left)) over budget"
            return "\(budget.name) \(state). The payment still goes through: Envelope can't stop it."
        }
    }
}

struct BudgetFormView: View {
    let budget: Budget?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var amountText: String
    @State private var errorMessage: String?

    init(budget: Budget?) {
        self.budget = budget
        _name = State(initialValue: budget?.name ?? "")
        _amountText = State(initialValue: MoneyField.text(budget?.monthlyCents))
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
                try context.save()
            } else {
                try BudgetService.addBudget(name: trimmed, monthlyCents: cents, in: context)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
