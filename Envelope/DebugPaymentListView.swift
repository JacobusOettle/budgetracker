import SwiftUI
import SwiftData
import AppIntents

/// Spike screen: lists every payment the App Intents received.
struct DebugPaymentListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DebugPayment.receivedAt, order: .reverse) private var payments: [DebugPayment]
    @State private var errorMessage: String?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Spike build. Every payment the Shortcuts automation sends is listed here exactly as received. Nothing is deducted from any budget yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if payments.isEmpty {
                    ContentUnavailableView(
                        "No payments yet",
                        systemImage: "creditcard",
                        description: Text("Tap Simulate to test logging, then set up the Transaction automation.")
                    )
                }

                ForEach(payments) { payment in
                    PaymentRow(payment: payment)
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(payments[index]) }
                    try? context.save()
                }
            }
            .navigationTitle("Envelope spike")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: shareText) { Label("Share log", systemImage: "square.and.arrow.up") }
                        .disabled(payments.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Simulate text payment") { Task { await simulateText() } }
                        Button("Simulate currency payment") { Task { await simulateCurrency() } }
                        Divider()
                        Button("Clear all", role: .destructive) { confirmClear = true }
                    } label: {
                        Label("Simulate", systemImage: "plus.circle")
                    }
                }
            }
            .confirmationDialog("Delete all logged payments?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) {
                    for payment in payments { context.delete(payment) }
                    try? context.save()
                }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var shareText: String {
        let header = "Envelope spike log (\(payments.count) entries)"
        return ([header] + payments.map(\.debugDescriptionLine)).joined(separator: "\n")
    }

    /// Runs the real intent code path with test data.
    private func simulateText() async {
        var intent = LogPaymentIntent()
        intent.amount = "R 1 234,56"
        intent.merchant = "Test Merchant"
        intent.card = "Simulated Card"
        intent.rawInput = "simulated"
        intent.sourceTag = "simulated-text"
        do { _ = try await intent.perform() } catch { errorMessage = error.localizedDescription }
    }

    private func simulateCurrency() async {
        var intent = LogPaymentCurrencyIntent()
        intent.amount = IntentCurrencyAmount(amount: Decimal(string: "42.50")!, currencyCode: "ZAR")
        intent.merchant = "Test Merchant"
        intent.card = "Simulated Card"
        intent.sourceTag = "simulated-currency"
        do { _ = try await intent.perform() } catch { errorMessage = error.localizedDescription }
    }
}

private struct PaymentRow: View {
    let payment: DebugPayment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(payment.formattedAmount).font(.headline)
                Spacer()
                if payment.possibleDuplicate {
                    Text("DUPLICATE?")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                Text(payment.source).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(payment.merchant.isEmpty ? "—" : payment.merchant) · \(payment.card.isEmpty ? "—" : payment.card)")
                .font(.subheadline)
            Text(payment.receivedAt, format: .dateTime.day().month().hour().minute().second())
                .font(.caption).foregroundStyle(.secondary)
            Text("raw amount: \"\(payment.rawAmount)\"")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if !payment.rawInput.isEmpty {
                Text("raw input: \"\(payment.rawInput)\"")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
    }
}
