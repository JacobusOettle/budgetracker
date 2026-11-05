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
        let armed = budgets.first { Arming.isArmed(armedAt: $0.armedAt, now: now) }

        ScrollView {
            VStack(spacing: 14) {
                if !unassigned.isEmpty || !review.isEmpty {
                    NavigationLink {
                        PaymentsListView(mode: .needsAttention)
                            .navigationTitle("To sort out")
                    } label: {
                        banner(attentionText(unassigned: unassigned.count, review: review.count),
                               systemImage: "exclamationmark.circle.fill", tint: .orange)
                    }
                    .buttonStyle(.plain)
                }

                if let month = unclosed.first {
                    Button {
                        monthEnd = MonthTarget(start: month)
                    } label: {
                        banner("Close \(MonthMath.name(month)): move leftovers to savings",
                               systemImage: "calendar.badge.checkmark", tint: .accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if budgets.isEmpty {
                    emptyState
                } else {
                    leftoverTotal(now: now)
                    if let armed {
                        armedBanner(armed, now: now)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(budgets) { budget in
                            tile(budget, now: now)
                        }
                    }
                    Text("Tap a budget just before you pay: the next payment in the following 10 minutes is logged to it. Tally can't block or change a payment. Long-press a budget to edit, recolour or move it, or drag it onto another.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// What's left across all budgets this month: what you could move to
    /// savings at month end if you spend nothing more. Same sum as Month End.
    private func leftoverTotal(now: Date) -> some View {
        let summary = MonthEnd.summary(budgets: allBudgets, payments: payments, month: now)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Left this month")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Money.format(cents: summary.toSaveCents))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(summary.totalLeftCents < 0 ? Color.red : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(leftoverCaption(summary))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private func armedBanner(_ budget: Budget, now: Date) -> some View {
        let left = budget.leftCents(now: now)
        let warning = BudgetWarning.level(leftCents: left, monthlyCents: budget.monthlyCents)
        let color = BudgetPalette.color(for: budget)
        let remaining = Arming.remaining(armedAt: budget.armedAt, now: now)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(budget.name) armed · \(Arming.countdown(remaining))")
                    .font(.headline.monospacedDigit())
                Text(armedMessage(budget, warning: warning, left: left))
                    .font(.subheadline)
                    .foregroundStyle(warning == .none ? Color.secondary : BudgetCard.color(for: warning))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func armedMessage(_ budget: Budget, warning: BudgetWarning, left: Int) -> String {
        switch warning {
        case .none:
            return "Pay now. The next payment goes to \(budget.name). Tap it again to disarm."
        case .low:
            return "Only \(Money.format(cents: left)) left. If you pay more, the payment still goes through: Tally can't stop it."
        case .empty:
            let state = left == 0 ? "is empty" : "is \(Money.format(cents: -left)) over budget"
            return "\(budget.name) \(state). The payment still goes through: Tally can't stop it."
        }
    }

    private func tile(_ budget: Budget, now: Date) -> some View {
        let index = budgets.firstIndex { $0.id == budget.id } ?? 0
        return Button {
            toggle(budget, now: now)
        } label: {
            BudgetTile(budget: budget, now: now)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit or recolour", systemImage: "paintpalette") { editingBudget = budget }
            Button("Payments", systemImage: "list.bullet") { viewingBudget = budget }
            if index > 0 {
                Button("Move earlier", systemImage: "arrow.left") {
                    perform { try BudgetService.move(budget, by: -1, in: context) }
                }
            }
            if index < budgets.count - 1 {
                Button("Move later", systemImage: "arrow.right") {
                    perform { try BudgetService.move(budget, by: 1, in: context) }
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { removingBudget = budget }
        }
        .draggable(budget.id.uuidString) {
            BudgetTile(budget: budget, now: now).frame(width: 140, height: 140)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)),
                  let dragged = budgets.first(where: { $0.id == id }),
                  dragged.id != budget.id else { return false }
            perform { try BudgetService.move(dragged, onto: budget, in: context) }
            return true
        }
        .sensoryFeedback(.impact, trigger: budget.armedAt)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add budgets like Food, Fuel and Fun, each with a monthly amount, or let the AI set them up from a bank statement.")
                .foregroundStyle(.secondary)
            Button("Add your first budget") { showingNewBudget = true }
                .buttonStyle(.borderedProminent)
            Button("Import a bank statement (PDF or CSV)…") { importingStatement = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
