import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Import a bank statement (CSV): the AI extracts the transactions and
/// proposes budgets; you review and edit before anything is saved.
struct StatementImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var importer: StatementImporter?
    @State private var choosingFile = false
    @State private var fileError: String?
    @State private var drafts: [StatementImport.ProposedBudget] = []
    @State private var amountTexts: [String: String] = [:]
    @State private var included: Set<String> = []
    @State private var importUnmatched = false

    private var aiReady: Bool { StatementImporter.fromSettings() != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let importer {
                    ImportProgressContainer(importer: importer) { stage in
                        content(for: stage, importer: importer)
                    }
                } else {
                    intro
                }
            }
            .navigationTitle("Import statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .fileImporter(isPresented: $choosingFile,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                          allowsMultipleSelection: true) { result in
                handle(result)
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    // MARK: Intro

    private var intro: some View {
        Form {
            Section {
                Text("Load your past spending from a bank statement, and let the AI set up budgets for you.")
                Text("In FNB or Capitec online banking, download your transaction history as a **CSV** file (not PDF). A few months to a year works best. You can pick more than one file.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("1. The whole file is sent to your AI provider, which extracts every transaction.\n2. It proposes budgets based on what you usually spend.\n3. You review and edit the budgets. Nothing is saved until you tap Import.")
                    .font(.callout)
            } header: {
                Text("How it works")
            }
            Section {
                if aiReady {
                    Button("Choose CSV file…") { choosingFile = true }
                } else {
                    NavigationLink("Set up an AI provider first") { AISettingsView() }
                }
                if let fileError {
                    Text(fileError).foregroundStyle(.red).font(.footnote)
                }
            } footer: {
                Text("Privacy: the statement goes to the AI provider you chose, including descriptions, amounts, balances and anything else in the file, such as an account number. Remove anything you don't want to share before importing. Keep Tally open while it works. A year of transactions can take a few minutes.")
            }
        }
    }

    // MARK: Stages

    @ViewBuilder
    private func content(for stage: StatementImporter.Stage, importer: StatementImporter) -> some View {
        switch stage {
        case .idle:
            ProgressView("Starting…")
        case let .reading(part, total, found):
            VStack(spacing: 16) {
                ProgressView(value: Double(part - 1), total: Double(max(total, 1)))
                    .padding(.horizontal, 40)
                Text("Reading part \(part) of \(total)…").font(.headline)
                Text("\(found) transactions found so far").foregroundStyle(.secondary)
                Text("Keep Tally open.").font(.footnote).foregroundStyle(.secondary)
            }
        case .proposing:
            VStack(spacing: 16) {
                ProgressView()
                Text("Setting up budgets from your spending…").font(.headline)
            }
        case .review:
            if let plan = importer.plan {
                review(plan, importer: importer)
            }
        case .done(let result):
            done(result)
        case .failed(let message):
            Form {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Section {
                    Button("Try again") {
                        self.importer = nil
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                }
            }
        }
    }

    private func review(_ plan: StatementImport.Plan, importer: StatementImporter) -> some View {
        let months = max(plan.summary.months, 1)
        return Form {
            Section {
                if let first = plan.summary.firstDate, let last = plan.summary.lastDate {
                    LabeledContent("Period", value: "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
                }
                LabeledContent("Spending payments", value: "\(plan.payments.count)")
                if plan.skippedNotSpending > 0 {
                    LabeledContent("Income & transfers (skipped)", value: "\(plan.skippedNotSpending)")
                }
                if plan.skippedDuplicates > 0 {
                    LabeledContent("Already in Tally (skipped)", value: "\(plan.skippedDuplicates)")
                }
            } header: {
                Text("Found")
            }

            Section {
                ForEach($drafts) { $draft in
                    let items = plan.payments(for: draft)
                    let total = items.reduce(0) { $0 + $1.transaction.cents }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { included.contains(draft.id) },
                            set: { if $0 { included.insert(draft.id) } else { included.remove(draft.id) } }
                        )) {
                            Text(draft.name).font(.headline)
                        }
                        if included.contains(draft.id) {
                            MoneyField(title: "Per month", text: Binding(
                                get: { amountTexts[draft.id] ?? MoneyField.text(draft.monthlyCents) },
                                set: { newValue in
                                    amountTexts[draft.id] = newValue
                                    if let cents = MoneyField.cents(newValue) { draft.monthlyCents = cents }
                                }
                            ))
                        }
                        Text("\(items.count) payments · you spent about \(Money.format(cents: total / months))/month")
                            .font(.caption).foregroundStyle(.secondary)
                        if !draft.categories.isEmpty {
                            Text(draft.categories.joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if existingBudgetNames.contains(draft.name.lowercased()) {
                            Text("You already have this budget. Payments go into it and its amount stays the same.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Suggested budgets")
            } footer: {
                Text("Edit the amounts, or switch off budgets you don't want. Switched-off budgets aren't created, and their payments aren't imported.")
            }

            if !plan.unmatched.isEmpty {
                Section {
                    Toggle("Also import \(plan.unmatched.count) payments that fit no budget", isOn: $importUnmatched)
                } footer: {
                    Text("They'd be added as Unassigned, for you to sort.")
                }
            }

            Section {
                Button {
                    var edited = plan
                    edited.budgets = drafts
                    importer.plan = edited
                    importer.apply(included: included, importUnmatched: importUnmatched, in: context)
                    UIApplication.shared.isIdleTimerDisabled = false
                } label: {
                    Text("Import").frame(maxWidth: .infinity).bold()
                }
                .disabled(included.isEmpty && !(importUnmatched && !plan.unmatched.isEmpty))
            } footer: {
                Text("Imported payments are marked **Imported**, and you can reassign any of them in History.")
            }
        }
        .onAppear {
            if drafts.isEmpty {
                drafts = plan.budgets
                included = Set(plan.budgets.map(\.id))
            }
        }
    }

    private var existingBudgetNames: Set<String> {
        Set(((try? BudgetService.activeBudgets(in: context)) ?? []).map { $0.name.lowercased() })
    }

    private func done(_ result: StatementImport.Result) -> some View {
        Form {
            Section {
                Label("Import complete", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                LabeledContent("Payments imported", value: "\(result.paymentsImported)")
                if result.budgetsCreated > 0 {
                    LabeledContent("Budgets created", value: "\(result.budgetsCreated)")
                }
                if result.budgetsReused > 0 {
                    LabeledContent("Existing budgets used", value: "\(result.budgetsReused)")
                }
                if result.unassignedImported > 0 {
                    LabeledContent("Unassigned, to sort", value: "\(result.unassignedImported)")
                }
            }
            Section {
                Button("Done") { dismiss() }
            } footer: {
                Text("This month's imported spending already counts towards your budgets. Past months are in History.")
            }
        }
    }

    // MARK: Files

    private func handle(_ result: Result<[URL], Error>) {
        fileError = nil
        switch result {
        case .failure(let error):
            fileError = error.localizedDescription
        case .success(let urls):
            var files: [(name: String, text: String)] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    fileError = "Couldn't read \(url.lastPathComponent)."
                    return
                }
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .windowsCP1252)
                    ?? String(decoding: data, as: UTF8.self)
                files.append((name: url.lastPathComponent, text: text))
            }
            guard !files.isEmpty, let importer = StatementImporter.fromSettings() else { return }
            drafts = []
            included = []
            amountTexts = [:]
            importUnmatched = false
            self.importer = importer
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await importer.run(files: files, in: context) }
        }
    }
}

/// Observes the importer so the screen updates as it works.
private struct ImportProgressContainer<Content: View>: View {
    @ObservedObject var importer: StatementImporter
    let content: (StatementImporter.Stage) -> Content

    var body: some View {
        content(importer.stage)
    }
}
