import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage(ReminderScheduler.enabledKey) private var reminderEnabled = true
    @AppStorage(ReminderScheduler.hourKey) private var reminderHour = ReminderScheduler.defaultHour
    @AppStorage(ReminderScheduler.minuteKey) private var reminderMinute = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Shortcuts setup guide") { SetupGuideView() }
                    TestPaymentButton()
                } header: {
                    Text("Apple Pay automation")
                }

                Section {
                    Toggle("Daily reminder", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Missed payments")
                } footer: {
                    Text("Online purchases, and taps the automation missed, aren't logged automatically. The reminder asks you to add them under History → +.")
                }

                Section("Data") {
                    NavigationLink("Export for AI analysis") { ExportView() }
                }

                Section {
                    Text("Everything stays on this iPhone. Envelope has no account, no bank connection and no analytics. It can't block, move or change money. It only records what you tell it, and what Apple Pay reports through Shortcuts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onChange(of: reminderEnabled) { reschedule() }
            .onChange(of: reminderHour) { reschedule() }
            .onChange(of: reminderMinute) { reschedule() }
        }
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: reminderHour, minute: reminderMinute)) ?? .now
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                reminderHour = parts.hour ?? ReminderScheduler.defaultHour
                reminderMinute = parts.minute ?? 0
            }
        )
    }

    private func reschedule() {
        Task { await ReminderScheduler.apply() }
    }
}

/// Runs the real payment path with a fake R12.34 payment.
struct TestPaymentButton: View {
    @Environment(\.modelContext) private var context
    @State private var result: String?

    var body: some View {
        Button("Send a test payment (R12.34)") {
            Task { await send() }
        }
        if let result {
            Text(result).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func send() async {
        do {
            let outcome = try PaymentProcessor.process(
                amountText: "R 12.34", merchant: "Test payment", card: "Test", source: .test, in: context
            )
            if let note = PaymentProcessor.notification(for: outcome) {
                await Notifier.post(title: note.title, body: note.body)
                result = "\(note.title). Delete it in History when you're done."
            } else {
                result = "Ignored as a duplicate of a test sent less than 2 minutes ago. That's the protection against double logging."
            }
        } catch {
            result = "Failed: \(error.localizedDescription)"
        }
    }
}

struct SetupGuideView: View {
    var body: some View {
        List {
            Section {
                Text("After you pay with Apple Pay, an iPhone Shortcuts automation tells Envelope the amount, shop and card. Envelope logs it to the budget you armed, or as Unassigned. Set it up once.")
            }
            Section("1. Create the automation") {
                step(1, "Open **Shortcuts** and tap **Automation** at the bottom.")
                step(2, "Tap **+** (top right), or **New Automation**.")
                step(3, "Tap **Wallet**. On iOS 17 and 18 it's called **Transaction**.")
                step(4, "Under **When I tap**, select every card you pay with.")
                step(5, "Leave all categories ticked and Merchant empty.")
                step(6, "Choose **Run Immediately**, then tap **Next**.")
                step(7, "Tap **New Blank Automation** (or **Create New Shortcut**).")
            }
            Section("2. Add Envelope's action") {
                step(8, "Search **Envelope** at the bottom and tap **Log Payment**.")
                step(9, "Tap **Amount**, tap **Shortcut Input** above the keyboard, then tap the blue bubble and choose **Amount**.")
                step(10, "Do the same for **Merchant**, choosing **Merchant**.")
                step(11, "Tap **›** on the action. For **Card**, choose **Shortcut Input → Card or Pass**. Leave Raw Input empty.")
                step(12, "Switch **Show When Run** off, then go back to save.")
            }
            Section {
                Text("Set up during testing? Delete the **Log Payment (Currency Amount)** action. It doesn't work and has been removed from the app.")
            } header: {
                Text("From the test build")
            }
            Section {
                TestPaymentButton()
            } header: {
                Text("3. Check it")
            } footer: {
                Text("The test runs inside Envelope. To test the automation itself, make a small real Apple Pay payment: the ▶︎ button in Shortcuts sends no payment details.")
            }
            Section("Good to know") {
                Text("• Online and in-app purchases don't trigger the automation. Add them by hand.")
                Text("• iPhone can occasionally miss or delay a payment. The daily reminder helps you catch these.")
                Text("• A declined tap may still be logged. Delete it in History.")
                Text("• If the same payment arrives twice within 2 minutes, it's only counted once.")
            }
        }
        .navigationTitle("Setup guide")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.bold().monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(text)
        }
    }
}
