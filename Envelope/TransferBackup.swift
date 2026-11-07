import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// TEMPORARY: moves everything from the old app (bundle ID ...envelope) to the
// renamed one (...spaar), which iOS treats as a different app with its own,
// empty storage. Delete this file and its row in Settings once moved.

/// A complete, lossless copy of the data and settings, as JSON.
struct TransferBackup: Codable {
    var format = "spaar-transfer"
    var version = 1
    var createdAt: Date

    var budgets: [BudgetRow]
    var payments: [PaymentRow]
    var monthCloses: [MonthCloseRow]
    var belongings: [BelongingRow]
    var ownerships: [OwnershipRow]
    var fundEntries: [FundEntryRow]
    var savingsAccounts: [SavingsRow]
    var settings: SettingsRow
    /// Only when you chose to include it.
    var apiKey: String?

    struct BudgetRow: Codable {
        var id: UUID, name: String, monthlyCents: Int, sortOrder: Int, createdAt: Date
        var archivedAt: Date?, armedAt: Date?, colorName: String
        var insertedAt: Date, originDevice: String, mergedIntoID: UUID?
    }
    struct PaymentRow: Codable {
        var id: UUID, amountCents: Int, merchant: String, card: String, date: Date
        var sourceRaw: String, rawAmount: String, note: String, needsReview: Bool
        var budgetID: UUID?, assignmentRaw: String, aiReason: String, aiAttempted: Bool
        var aiOriginalBudgetName: String, statementMatched: Bool
    }
    struct MonthCloseRow: Codable {
        var monthKey: String, closedAt: Date, totalLeftCents: Int, unassignedCents: Int
        var toSaveCents: Int, movedCents: Int, replacementCents: Int, linesJSON: String
    }
    struct BelongingRow: Codable {
        var id: UUID, name: String, categoryRaw: String, createdAt: Date
        var previousLifespanMonths: Int?, archived: Bool
    }
    struct OwnershipRow: Codable {
        var id: UUID, belongingID: UUID?, purchasedOn: Date, priceCents: Int
        var replacementCostCents: Int?, customLifespanMonths: Int?
        var retiredOn: Date?, retiredReason: String?
    }
    struct FundEntryRow: Codable {
        var id: UUID, belongingID: UUID?, date: Date, kindRaw: String, cents: Int
        var monthKey: String?, note: String
    }
    struct SavingsRow: Codable {
        var balanceCents: Int, updatedAt: Date, isProvisional: Bool, deltaCents: Int, balanceSetAt: Date?
    }
    /// The app's settings stored outside the database.
    struct SettingsRow: Codable {
        var aiConfig: Data?
        var reminderEnabled: Bool?
        var reminderHour: Int?
        var reminderMinute: Int?
        var setupBannerHidden: Bool?
        var usageStart: Date?
    }

    static let settingsKeys = (
        aiConfig: "ai.config",
        reminderEnabled: "reminder.enabled",
        reminderHour: "reminder.hour",
        reminderMinute: "reminder.minute",
        setupBannerHidden: "setupBanner.hidden",
        usageStart: UsageStart.key
    )

    // MARK: Export

    static func make(context: ModelContext, includeAPIKey: Bool, defaults: UserDefaults = .standard, now: Date = .now) throws -> TransferBackup {
        let k = settingsKeys
        return TransferBackup(
            createdAt: now,
            budgets: try context.fetch(FetchDescriptor<Budget>()).map {
                BudgetRow(id: $0.id, name: $0.name, monthlyCents: $0.monthlyCents, sortOrder: $0.sortOrder,
                          createdAt: $0.createdAt, archivedAt: $0.archivedAt, armedAt: $0.armedAt,
                          colorName: $0.colorName, insertedAt: $0.insertedAt, originDevice: $0.originDevice,
                          mergedIntoID: $0.mergedIntoID)
            },
            payments: try context.fetch(FetchDescriptor<Payment>()).map {
                PaymentRow(id: $0.id, amountCents: $0.amountCents, merchant: $0.merchant, card: $0.card,
                           date: $0.date, sourceRaw: $0.sourceRaw, rawAmount: $0.rawAmount, note: $0.note,
                           needsReview: $0.needsReview, budgetID: $0.budget?.id, assignmentRaw: $0.assignmentRaw,
                           aiReason: $0.aiReason, aiAttempted: $0.aiAttempted,
                           aiOriginalBudgetName: $0.aiOriginalBudgetName, statementMatched: $0.statementMatched)
            },
            monthCloses: try context.fetch(FetchDescriptor<MonthClose>()).map {
                MonthCloseRow(monthKey: $0.monthKey, closedAt: $0.closedAt, totalLeftCents: $0.totalLeftCents,
                              unassignedCents: $0.unassignedCents, toSaveCents: $0.toSaveCents,
                              movedCents: $0.movedCents, replacementCents: $0.replacementCents, linesJSON: $0.linesJSON)
            },
            belongings: try context.fetch(FetchDescriptor<Belonging>()).map {
                BelongingRow(id: $0.id, name: $0.name, categoryRaw: $0.categoryRaw, createdAt: $0.createdAt,
                             previousLifespanMonths: $0.previousLifespanMonths, archived: $0.archived)
            },
            ownerships: try context.fetch(FetchDescriptor<Ownership>()).map {
                OwnershipRow(id: $0.id, belongingID: $0.belonging?.id, purchasedOn: $0.purchasedOn,
                             priceCents: $0.priceCents, replacementCostCents: $0.replacementCostCents,
                             customLifespanMonths: $0.customLifespanMonths, retiredOn: $0.retiredOn,
                             retiredReason: $0.retiredReason)
            },
            fundEntries: try context.fetch(FetchDescriptor<FundEntry>()).map {
                FundEntryRow(id: $0.id, belongingID: $0.belonging?.id, date: $0.date, kindRaw: $0.kindRaw,
                             cents: $0.cents, monthKey: $0.monthKey, note: $0.note)
            },
            savingsAccounts: try context.fetch(FetchDescriptor<SavingsAccount>()).map {
                SavingsRow(balanceCents: $0.balanceCents, updatedAt: $0.updatedAt, isProvisional: $0.isProvisional,
                           deltaCents: $0.deltaCents, balanceSetAt: $0.balanceSetAt)
            },
            settings: SettingsRow(
                aiConfig: defaults.data(forKey: k.aiConfig),
                reminderEnabled: defaults.object(forKey: k.reminderEnabled) as? Bool,
                reminderHour: defaults.object(forKey: k.reminderHour) as? Int,
                reminderMinute: defaults.object(forKey: k.reminderMinute) as? Int,
                setupBannerHidden: defaults.object(forKey: k.setupBannerHidden) as? Bool,
                usageStart: defaults.object(forKey: k.usageStart) as? Date
            ),
            apiKey: includeAPIKey ? KeychainStore.get(AIConfig.keychainAccount) : nil
        )
    }

    static func encode(_ backup: TransferBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> TransferBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(TransferBackup.self, from: data)
        guard backup.format == "spaar-transfer" else { throw TransferError.notATransferFile }
        guard backup.version <= 1 else { throw TransferError.newerVersion }
        return backup
    }

    static func writeFile(context: ModelContext, includeAPIKey: Bool, now: Date = .now) throws -> URL {
        let data = try encode(make(context: context, includeAPIKey: includeAPIKey, now: now))
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        let url = FileManager.default.temporaryDirectory.appending(path: "spaar-transfer-\(day).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: Import

    struct Summary: Equatable {
        var budgets = 0, payments = 0, monthCloses = 0, belongings = 0
    }

    /// Replaces everything in the database with the backup and restores the
    /// settings. Ids are kept, so the same file never creates two copies.
    @discardableResult
    static func restore(_ backup: TransferBackup, into context: ModelContext, defaults: UserDefaults = .standard) throws -> Summary {
        try context.delete(model: Payment.self)
        try context.delete(model: Budget.self)
        try context.delete(model: MonthClose.self)
        try context.delete(model: FundEntry.self)
        try context.delete(model: Ownership.self)
        try context.delete(model: Belonging.self)
        try context.delete(model: SavingsAccount.self)

        var budgetsByID: [UUID: Budget] = [:]
        for row in backup.budgets {
            let b = Budget(name: row.name, monthlyCents: row.monthlyCents, sortOrder: row.sortOrder, createdAt: row.createdAt)
            b.id = row.id
            b.archivedAt = row.archivedAt
            b.armedAt = nil   // never arrive armed
            b.colorName = row.colorName
            b.insertedAt = row.insertedAt
            b.originDevice = row.originDevice
            b.mergedIntoID = row.mergedIntoID
            context.insert(b)
            budgetsByID[row.id] = b
        }
        for row in backup.payments {
            let p = Payment(amountCents: row.amountCents, merchant: row.merchant, card: row.card, date: row.date,
                            source: PaymentSource(rawValue: row.sourceRaw) ?? .manual, rawAmount: row.rawAmount,
                            note: row.note, needsReview: row.needsReview)
            p.id = row.id
            p.sourceRaw = row.sourceRaw
            p.assignmentRaw = row.assignmentRaw
            p.aiReason = row.aiReason
            p.aiAttempted = row.aiAttempted
            p.aiOriginalBudgetName = row.aiOriginalBudgetName
            p.statementMatched = row.statementMatched
            context.insert(p)
            p.budget = row.budgetID.flatMap { budgetsByID[$0] }
        }
        for row in backup.monthCloses {
            let c = MonthClose(monthKey: row.monthKey, closedAt: row.closedAt,
                               summary: MonthEndSummary(lines: [], unassignedCents: 0, unassignedCount: 0),
                               movedCents: row.movedCents, replacementCents: row.replacementCents)
            c.totalLeftCents = row.totalLeftCents
            c.unassignedCents = row.unassignedCents
            c.toSaveCents = row.toSaveCents
            c.linesJSON = row.linesJSON
            context.insert(c)
        }
        var belongingsByID: [UUID: Belonging] = [:]
        for row in backup.belongings {
            let b = Belonging(name: row.name, category: BelongingCategory(rawValue: row.categoryRaw) ?? .other,
                              previousLifespanMonths: row.previousLifespanMonths, createdAt: row.createdAt)
            b.id = row.id
            b.categoryRaw = row.categoryRaw
            b.archived = row.archived
            context.insert(b)
            belongingsByID[row.id] = b
        }
        for row in backup.ownerships {
            let o = Ownership(purchasedOn: row.purchasedOn, priceCents: row.priceCents,
                              replacementCostCents: row.replacementCostCents, customLifespanMonths: row.customLifespanMonths)
            o.id = row.id
            o.retiredOn = row.retiredOn
            o.retiredReason = row.retiredReason
            context.insert(o)
            o.belonging = row.belongingID.flatMap { belongingsByID[$0] }
        }
        for row in backup.fundEntries {
            let e = FundEntry(date: row.date, kind: FundEntryKind(rawValue: row.kindRaw) ?? .adjustment,
                              cents: row.cents, monthKey: row.monthKey, note: row.note)
            e.id = row.id
            e.kindRaw = row.kindRaw
            context.insert(e)
            e.belonging = row.belongingID.flatMap { belongingsByID[$0] }
        }
        for row in backup.savingsAccounts {
            let s = SavingsAccount(balanceCents: row.balanceCents, updatedAt: row.updatedAt)
            s.isProvisional = row.isProvisional
            s.deltaCents = row.deltaCents
            s.balanceSetAt = row.balanceSetAt
            context.insert(s)
        }
        try context.save()

        let k = settingsKeys
        let s = backup.settings
        if let v = s.aiConfig { defaults.set(v, forKey: k.aiConfig) }
        if let v = s.reminderEnabled { defaults.set(v, forKey: k.reminderEnabled) }
        if let v = s.reminderHour { defaults.set(v, forKey: k.reminderHour) }
        if let v = s.reminderMinute { defaults.set(v, forKey: k.reminderMinute) }
        if let v = s.setupBannerHidden { defaults.set(v, forKey: k.setupBannerHidden) }
        if let v = s.usageStart { defaults.set(v, forKey: k.usageStart) }
        if let key = backup.apiKey, !key.isEmpty {
            _ = KeychainStore.set(key, for: AIConfig.keychainAccount)
        }
        return Summary(budgets: backup.budgets.count, payments: backup.payments.count,
                       monthCloses: backup.monthCloses.count, belongings: backup.belongings.count)
    }
}

enum TransferError: LocalizedError {
    case notATransferFile, newerVersion
    var errorDescription: String? {
        switch self {
        case .notATransferFile: "This isn't a Spaar transfer file. Use the file from \"Back up for transfer\", not the AI export."
        case .newerVersion: "This file was made by a newer version of Spaar. Update Spaar and try again."
        }
    }
}

/// Settings → Move to the new Spaar app.
struct TransferView: View {
    @Environment(\.modelContext) private var context
    @State private var includeAPIKey = false
    @State private var fileURL: URL?
    @State private var choosingFile = false
    @State private var pending: TransferBackup?
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Moves all your budgets, payments, month ends, belongings, savings and settings to another copy of Spaar, such as the renamed app.")
            }
            Section {
                Toggle("Include AI API key", isOn: $includeAPIKey)
                Button("Create backup file") { create() }
                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("Save \(fileURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("1. On the old app: back up")
            } footer: {
                Text("Save it to Files (On My iPhone or iCloud Drive). The file isn't encrypted; with the API key included, keep it private and delete it after moving.")
            }
            Section {
                Button("Restore from backup file…") { choosingFile = true }
                if let message {
                    Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            } header: {
                Text("2. On the new app: restore")
            } footer: {
                Text("Replaces everything in this copy of Spaar with the backup. Afterwards, set up the Apple Pay automation again for this app (Settings → Set up Apple Pay logging): automations point at one app.")
            }
        }
        .navigationTitle("Move to new app")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            load(result)
        }
        .confirmationDialog("Replace everything?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Replace with backup", role: .destructive) { restore() }
        } message: {
            if let pending {
                Text("Backup from \(pending.createdAt.formatted(date: .abbreviated, time: .shortened)): \(pending.budgets.count) budgets, \(pending.payments.count) payments, \(pending.belongings.count) belongings. Everything currently in this app is replaced.")
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func create() {
        do { fileURL = try TransferBackup.writeFile(context: context, includeAPIKey: includeAPIKey) }
        catch { errorMessage = error.localizedDescription }
    }

    private func load(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pending = try TransferBackup.decode(Data(contentsOf: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() {
        guard let backup = pending else { return }
        pending = nil
        do {
            let s = try TransferBackup.restore(backup, into: context)
            message = "Restored \(s.budgets) budgets, \(s.payments) payments, \(s.monthCloses) month ends and \(s.belongings) belongings."
            Task { await ReminderScheduler.apply() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
