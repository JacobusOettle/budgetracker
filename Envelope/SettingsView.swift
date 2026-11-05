import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage(ReminderScheduler.enabledKey) private var reminderEnabled = true
    @AppStorage(ReminderScheduler.hourKey) private var reminderHour = ReminderScheduler.defaultHour
    @AppStorage(ReminderScheduler.minuteKey) private var reminderMinute = 0
    @State private var importingStatement = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Set up Apple Pay logging") { SetupGuideView() }
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

                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        LabeledContent("Auto-categorise with AI", value: aiSummary)
                    }
                } footer: {
                    Text("When no budget is armed, an AI model of your choice can pick the budget for you.")
                }

                Section("Data") {
                    Button("Import bank statement (CSV)…") { importingStatement = true }
                    NavigationLink("Export for AI analysis") { ExportView() }
                }

                Section {
                    Text("Everything stays on this iPhone unless you use a cloud AI provider (Apple Intelligence runs on the phone). Tally has no account, no bank connection and no analytics. It can't block, move or change money. It only records what you tell it, and what Apple Pay reports through Shortcuts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $importingStatement) { StatementImportView() }
            .onChange(of: reminderEnabled) { reschedule() }
            .onChange(of: reminderHour) { reschedule() }
            .onChange(of: reminderMinute) { reschedule() }
        }
    }

    private var aiSummary: String {
        let config = AIConfig.load()
        guard config.enabled else { return "Off" }
        switch config.resolvedCategorizer(appleAvailable: OnDeviceAI.isAvailable) {
        case .appleOnDevice: return OnDeviceAI.isAvailable ? "Apple Intelligence" : "Unavailable"
        default: return config.cloudIsConfigured ? AIPreset.named(config.presetID).name : "Not set up"
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

/// Sets up the Shortcuts automation that tells Tally about Apple Pay taps.
/// iOS doesn't let apps create automations themselves, so this makes it as
/// short as possible: a ready-made "Log to Tally" shortcut added with one tap,
/// then a few taps in Shortcuts, and a live check that it works.
struct SetupGuideView: View {
    @Environment(\.openURL) private var openURL
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @State private var showManual = false

    private var lastApplePay: Payment? { payments.first { $0.source == .shortcut } }

    var body: some View {
        List {
            Section {
                if let last = lastApplePay {
                    Label("Working. Last Apple Pay payment logged \(last.date.formatted(date: .abbreviated, time: .shortened)).",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not set up yet. Once it's set up, your next Apple Pay tap shows up here.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("After you pay with Apple Pay, with any card from any bank, an iPhone Shortcuts automation tells Tally the amount, shop and card. iOS doesn't let apps create automations themselves, so it takes a minute to set up once.")
            }

            if let link = TallyLinks.logPaymentShortcut {
                Section {
                    Button {
                        openURL(link)
                    } label: {
                        Label("Add the “Log to Tally” shortcut", systemImage: "plus.square.on.square")
                    }
                } header: {
                    Text("1. Add the shortcut")
                } footer: {
                    Text("Opens Shortcuts. Tap **Add Shortcut**, then come back here.")
                }

                Section {
                    Button {
                        openURL(URL(string: "shortcuts://")!)
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    }
                    step(1, "Tap **Automation** at the bottom, then **+**.")
                    step(2, "Tap **Wallet** (called **Transaction** on older iOS).")
                    step(3, "Under **When I tap**, choose **Any card**, or tick all your cards.")
                    step(4, "Choose **Run Immediately**, then **Next**.")
                    step(5, "Tap **Log to Tally** in the list. Done.")
                } header: {
                    Text("2. Turn it on for every tap")
                }

                Section {
                    DisclosureGroup("Set it up by hand instead", isExpanded: $showManual) {
                        manualSteps
                    }
                }
            } else {
                Section {
                    Button {
                        openURL(URL(string: "shortcuts://")!)
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    }
                    manualSteps
                } header: {
                    Text("Set up the automation")
                }
            }

            Section {
                TestPaymentButton()
            } header: {
                Text("Check it")
            } footer: {
                Text("The test runs inside Tally. To check the automation, make a small real Apple Pay payment: the ▶︎ button in Shortcuts sends no payment details.")
            }

            Section("Good to know") {
                Text("• Works with any card in Apple Wallet, from any bank.")
                Text("• Online and in-app purchases don't trigger the automation. Add them by hand.")
                Text("• iPhone can occasionally miss or delay a payment. The daily reminder helps you catch these.")
                Text("• A declined tap may still be logged. Delete it in History.")
                Text("• If the same payment arrives twice within 2 minutes, it's only counted once.")
            }
        }
        .navigationTitle("Apple Pay logging")
    }

    @ViewBuilder
    private var manualSteps: some View {
        step(1, "In **Shortcuts**, tap **Automation**, then **+**.")
        step(2, "Tap **Wallet** (called **Transaction** on older iOS).")
        step(3, "Under **When I tap**, choose **Any card**, or tick all your cards. Leave categories and merchants as they are.")
        step(4, "Choose **Run Immediately**, then **Next**, then **New Blank Automation**.")
        step(5, "Search **Tally** and tap **Log Payment**.")
        step(6, "Tap **Amount** → **Shortcut Input** above the keyboard → tap the blue bubble → **Amount**.")
        step(7, "Do the same for **Merchant** (→ **Merchant**) and, under **›**, **Card** (→ **Card or Pass**).")
        step(8, "Switch **Show When Run** off and save.")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.bold().monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(text)
        }
    }
}
