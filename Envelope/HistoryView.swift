import SwiftUI
import SwiftData

struct HistoryView: View {
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            PaymentsListView(mode: .all)
                .navigationTitle("History")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingNew = true } label: { Label("Add payment", systemImage: "plus") }
                    }
                }
                .sheet(isPresented: $showingNew) { PaymentFormView(payment: nil) }
        }
    }
}

/// Payment list. Tap to edit or reassign, swipe to delete, long-press to
/// assign quickly.
struct PaymentsListView: View {
    enum Mode {
        case all
        case needsAttention
        case budget(Budget)
    }

    let mode: Mode

    @Environment(\.modelContext) private var context
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \Budget.sortOrder) private var sortedBudgets: [Budget]
    private var budgets: [Budget] { sortedBudgets.filter { $0.archivedAt == nil } }
    @State private var editing: Payment?

    init(mode: Mode) {
        self.mode = mode
    }

    private var filtered: [Payment] {
        switch mode {
        case .all: payments
        case .needsAttention: payments.filter { $0.budget == nil || $0.needsReview }
        case .budget(let budget): payments.filter { $0.budget?.id == budget.id }
        }
    }

    private struct MonthGroup: Identifiable {
        let key: String
        let title: String
        let payments: [Payment]
        var id: String { key }
    }

    private func groups(_ list: [Payment]) -> [MonthGroup] {
        let grouped = Dictionary(grouping: list) { ReplacementPlanner.monthKey(for: $0.date) }
        return grouped.keys.sorted(by: >).map { key in
            let items = grouped[key] ?? []
            return MonthGroup(key: key, title: items.first.map { MonthMath.name($0.date) } ?? key, payments: items)
        }
    }

    var body: some View {
        let list = filtered
        let attention: [Payment] = {
            if case .all = mode { return list.filter { $0.budget == nil || $0.needsReview } }
            return []
        }()
        let attentionIDs = Set(attention.map(\.id))
        let rest = list.filter { !attentionIDs.contains($0.id) }

        List {
            if list.isEmpty {
                ContentUnavailableView("No payments", systemImage: "creditcard",
                                       description: Text("Apple Pay payments appear here once the Shortcuts automation is set up. Add online purchases with +."))
            }
            if !attention.isEmpty {
                Section("To sort out") {
                    ForEach(attention) { row($0) }
                        .onDelete { delete(attention, at: $0) }
                }
            }
            ForEach(groups(rest)) { group in
                Section {
                    ForEach(group.payments) { row($0) }
                        .onDelete { delete(group.payments, at: $0) }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text(Money.format(cents: group.payments.reduce(0) { $0 + $1.amountCents }))
                    }
                }
            }
        }
        .sheet(item: $editing) { PaymentFormView(payment: $0) }
    }

    private func row(_ payment: Payment) -> some View {
        Button {
            editing = payment
        } label: {
            PaymentRow(payment: payment)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Assign to") {
                Button("Unassigned") { assign(payment, to: nil) }
                ForEach(budgets) { budget in
                    Button(budget.name) { assign(payment, to: budget) }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                context.delete(payment)
                try? context.save()
            }
        }
    }

    private func assign(_ payment: Payment, to budget: Budget?) {
        payment.budget = budget
        try? context.save()
    }

    private func delete(_ items: [Payment], at offsets: IndexSet) {
        for index in offsets { context.delete(items[index]) }
        try? context.save()
    }
}

struct PaymentRow: View {
    let payment: Payment

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(payment.displayMerchant).font(.body)
                HStack(spacing: 4) {
                    if let budget = payment.budget {
                        Text(budget.name).foregroundStyle(.secondary)
                    } else {
                        Text("Unassigned").foregroundStyle(.orange).bold()
                    }
                    Text("·").foregroundStyle(.secondary)
                    Text(payment.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if payment.needsReview {
                    Label(payment.note.isEmpty ? "Check this payment" : payment.note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Money.format(cents: payment.amountCents)).monospacedDigit()
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch payment.source {
        case .shortcut: "wave.3.right"
        case .manual: "square.and.pencil"
        case .test: "testtube.2"
        }
    }
}

/// Add a payment by hand (online purchases, missed taps) or edit/reassign one.
struct PaymentFormView: View {
    let payment: Payment?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Budget.sortOrder) private var allBudgets: [Budget]

    @State private var amountText: String
    @State private var merchant: String
    @State private var date: Date
    @State private var budgetID: UUID?
    @State private var note: String
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    init(payment: Payment?) {
        self.payment = payment
        _amountText = State(initialValue: MoneyField.text(payment?.amountCents))
        _merchant = State(initialValue: payment?.merchant ?? "")
        _date = State(initialValue: payment?.date ?? .now)
        _budgetID = State(initialValue: payment?.budget?.id)
        _note = State(initialValue: payment?.note ?? "")
    }

    private var cents: Int? { MoneyField.cents(amountText) }

    /// Active budgets, plus the payment's current one even if it was removed.
    private var budgetOptions: [Budget] {
        allBudgets.filter { $0.archivedAt == nil || $0.id == payment?.budget?.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MoneyField(title: "Amount", text: $amountText)
                    TextField("Where? e.g. Takealot", text: $merchant)
                    DatePicker("When", selection: $date, in: ...Date().addingTimeInterval(3600))
                }
                Section {
                    Picker("Budget", selection: $budgetID) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(budgetOptions) { budget in
                            Text(budget.archivedAt == nil ? budget.name : "\(budget.name) (removed)")
                                .tag(UUID?.some(budget.id))
                        }
                    }
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
                if let payment, payment.source == .shortcut {
                    Section("From Apple Pay") {
                        LabeledContent("Card", value: payment.card.isEmpty ? "—" : payment.card)
                        LabeledContent("Amount received", value: payment.rawAmount)
                    }
                }
                if payment != nil {
                    Section {
                        Button("Delete payment", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(payment == nil ? "Add payment" : "Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled((cents ?? 0) <= 0)
                }
            }
            .confirmationDialog("Delete this payment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let payment { context.delete(payment) }
                    try? context.save()
                    dismiss()
                }
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
        let budget = allBudgets.first { $0.id == budgetID }
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespaces)
        do {
            if let payment {
                payment.amountCents = cents
                payment.merchant = trimmedMerchant
                payment.date = date
                payment.budget = budget
                payment.note = note
                payment.needsReview = false
            } else {
                let new = Payment(amountCents: cents, merchant: trimmedMerchant, card: "", date: date, source: .manual, note: note)
                context.insert(new)
                new.budget = budget
            }
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
