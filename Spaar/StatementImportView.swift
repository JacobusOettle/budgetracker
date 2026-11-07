import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

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
    /// Possible matches you said are different payments.
    @State private var rejectedMerges: Set<String> = []
    @State private var aiReady = false
    @State private var runTask: Task<Void, Never>?
    /// Files waiting to start; a locked PDF here needs its password first.
    @State private var pendingFiles: [StatementImport.File] = []
    @State private var lockedName: String?
    @State private var password = ""

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
            .alert("Statement password", isPresented: Binding(get: { lockedName != nil }, set: { if !$0 { lockedName = nil } })) {
                SecureField("Password", text: $password)
                Button("Unlock") { unlockPending() }
                Button("Cancel", role: .cancel) {
                    pendingFiles = []
                    password = ""
                }
            } message: {
                Text("\(lockedName ?? "This PDF") is password protected. Banks often use your ID number or a number from the email. It's only used on this phone.")
            }
            .fileImporter(isPresented: $choosingFile,
                          allowedContentTypes: [.pdf, .commaSeparatedText, .plainText, .text],
                          allowsMultipleSelection: true) { result in
                handle(result)
            }
            .onDisappear {
                // Closing the screen stops the import: nothing more is sent.
                runTask?.cancel()
                runTask = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: Intro

    private var intro: some View {
        Form {
            Section {
                Text("Load your past spending from a bank statement, and let the AI set up budgets for you.")
                Text("Use the **PDF statements** your bank emails you or that you download from FNB or Capitec online banking, or a **CSV** transaction export. A few months to a year works best. You can pick more than one file.")
                    .foregroundStyle(.secondary)
                Text("Password-protected statements are fine: Spaar asks for the password and unlocks the file on your phone. The password is never sent anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("1. The statement is sent to your AI provider, which extracts every transaction. Claude reads PDF pages directly, even scanned ones. Other providers get the text inside the PDF.\n2. It proposes budgets based on what you usually spend.\n3. You review and edit the budgets. Nothing is saved until you tap Import.")
                    .font(.callout)
            } header: {
                Text("How it works")
            }
            Section {
                if aiReady {
                    Button("Choose statement (PDF or CSV)…") { choosingFile = true }
                } else {
                    Text("Importing needs a cloud AI provider such as Claude: Apple's on-device model is too small to read whole statements. Apple Intelligence keeps sorting your everyday payments either way.")
                        .font(.footnote)
                    NavigationLink("Set up a cloud provider") { AISettingsView() }
                }
                if let fileError {
                    Text(fileError).foregroundStyle(.red).font(.footnote)
                }
            } footer: {
                Text("Privacy: the statement goes to the AI provider you chose, including descriptions, amounts, balances and anything else in it, such as your name, address and account number. Remove anything you don't want to share before importing. Keep Spaar open while it works. A year of transactions can take a few minutes.")
            }
        }
        .onAppear { aiReady = StatementImporter.fromSettings() != nil }
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
                Text("Keep Spaar open.").font(.footnote).foregroundStyle(.secondary)
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
                        runTask?.cancel()
                        runTask = nil
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
                LabeledContent("New payments", value: "\(plan.payments.count)")
                if !plan.exactMerges.isEmpty {
                    LabeledContent("Already in Spaar (merged)", value: "\(plan.exactMerges.count)")
                }
                if plan.skippedNotSpending > 0 {
                    LabeledContent("Income & transfers (skipped)", value: "\(plan.skippedNotSpending)")
                }
                if plan.skippedDuplicates > 0 {
                    LabeledContent("Repeated in overlapping files (skipped)", value: "\(plan.skippedDuplicates)")
                }
            } header: {
                Text("Found")
            } footer: {
                let fills = plan.exactMerges.filter(\.fillsInBudget).count
                if !plan.exactMerges.isEmpty {
                    Text("Payments you already have (from Apple Pay, typed in, or an earlier import) are kept as they are and not added again. They're matched by amount within 3 days, because banks often show a later date.\(fills > 0 ? " \(fills) of them have no budget yet and will get one." : "")")
                }
            }

            if !plan.possibleMerges.isEmpty {
                Section {
                    ForEach(plan.possibleMerges) { merge in
                        Toggle(isOn: Binding(
                            get: { !rejectedMerges.contains(merge.id) },
                            set: { if $0 { rejectedMerges.remove(merge.id) } else { rejectedMerges.insert(merge.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Statement: \(merge.transaction.description) · \(Money.format(cents: merge.transaction.cents))")
                                    .font(.subheadline)
                                Text("In Spaar: \(merge.existing.merchant.isEmpty ? "Payment" : merge.existing.merchant) · \(merge.existing.cents == 0 ? "amount unknown" : Money.format(cents: merge.existing.cents))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(merge.transaction.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Same payment?")
                } footer: {
                    Text("Same shop with a different amount is usually a fuel pre-authorisation, a tip, or an amount Apple Pay couldn't read: merged unless you switch it off. Same amount at a differently named shop may be a payment on another card: kept separate unless you switch it on. Merging keeps your payment and uses the bank's amount.")
                }
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
                    importer.apply(included: included, importUnmatched: importUnmatched, rejectedMerges: rejectedMerges, in: context)
                    UIApplication.shared.isIdleTimerDisabled = false
                } label: {
                    Text("Import").frame(maxWidth: .infinity).bold()
                }
                .disabled(included.isEmpty && !(importUnmatched && !plan.unmatched.isEmpty) && plan.merges.isEmpty)
            } footer: {
                Text("Imported payments are marked **Imported**, and you can reassign any of them in History.")
            }
        }
        .onAppear {
            if drafts.isEmpty {
                drafts = plan.budgets
                included = Set(plan.budgets.map(\.id))
                // Different-looking names: kept separate unless you say otherwise.
                rejectedMerges = Set(plan.possibleMerges.filter { !$0.mergedByDefault }.map(\.id))
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
                LabeledContent("New payments", value: "\(result.paymentsImported)")
                if result.merged > 0 {
                    LabeledContent("Merged with payments you had", value: "\(result.merged)")
                }
                if result.budgetsFilledIn > 0 {
                    LabeledContent("Budgets filled in", value: "\(result.budgetsFilledIn)")
                }
                if result.amountsUpdated > 0 {
                    LabeledContent("Amounts corrected", value: "\(result.amountsUpdated)")
                }
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
            var files: [StatementImport.File] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    fileError = "Couldn't read \(url.lastPathComponent)."
                    return
                }
                let name = url.lastPathComponent
                if url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF".utf8)) {
                    guard let document = PDFDocument(data: data) else {
                        fileError = StatementImport.ImportError.unreadable(name).localizedDescription
                        return
                    }
                    files.append(.pdf(name: name, document: document))
                } else {
                    let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .windowsCP1252)
                        ?? String(decoding: data, as: UTF8.self)
                    files.append(.csv(name: name, text: text))
                }
            }
            guard !files.isEmpty else { return }
            pendingFiles = files
            continuePending()
        }
    }

    /// Asks for the next locked PDF's password, or starts once all are open.
    private func continuePending() {
        for file in pendingFiles {
            if case let .pdf(name, document) = file, document.isLocked {
                password = ""
                lockedName = name
                return
            }
        }
        start(pendingFiles)
        pendingFiles = []
    }

    private func unlockPending() {
        guard let name = lockedName else { return }
        let attempt = password
        password = ""
        lockedName = nil
        for file in pendingFiles {
            if case let .pdf(fileName, document) = file, fileName == name {
                if !document.unlock(withPassword: attempt) {
                    fileError = "Wrong password for \(name). Try again."
                    pendingFiles = []
                    return
                }
            }
        }
        // Show the next prompt after this alert has closed.
        DispatchQueue.main.async { continuePending() }
    }

    private func start(_ files: [StatementImport.File]) {
        guard !files.isEmpty, let importer = StatementImporter.fromSettings() else { return }
        drafts = []
        included = []
        amountTexts = [:]
        importUnmatched = false
        rejectedMerges = []
        self.importer = importer
        UIApplication.shared.isIdleTimerDisabled = true
        runTask?.cancel()
        runTask = Task { await importer.run(files: files, in: context) }
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
