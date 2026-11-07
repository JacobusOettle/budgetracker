import Foundation
import SwiftData
import CloudKit
import CoreData
import Observation

/// iCloud sync: SwiftData mirrors the whole store to the user's own private
/// CloudKit database, so budgets, payments, belongings and month ends follow
/// them to every iPhone signed in to the same Apple Account. Nothing goes to
/// us; there is no server.
///
/// Stays on this phone (not synced): AI settings and API key, the Shortcuts
/// automation, notification and reminder settings.
enum CloudSync {
    /// The CloudKit container this build was signed for, from Info.plist
    /// (`SpaarCloudKitContainer` = `iCloud.<bundle id>`). It's empty in builds
    /// without the iCloud entitlement (sideloaded IPAs, tests), and then
    /// CloudKit is never touched: touching it without the entitlement crashes.
    static var containerID: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SpaarCloudKitContainer") as? String
        return validContainer(raw)
    }

    static func validContainer(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("iCloud."), !value.contains("$("), value.count > "iCloud.".count else { return nil }
        return value
    }

    static var isInBuild: Bool { containerID != nil }

    static let enabledKey = "cloudSync.enabled"

    /// The user's choice in Settings, applied at launch. See `decideDefault`.
    static var userWantsSync: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// First launch with sync in the app: on for a fresh install, but off
    /// when this phone already has data. Those users turn it on themselves
    /// in Settings after reading what it does (and a backup is made first).
    static func decideDefault(storeExists: Bool, defaults: UserDefaults = .standard) {
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set(!storeExists, forKey: enabledKey)
        }
    }

    /// A random id for this install (not synced). Stamped on new budgets so
    /// duplicates can be told apart from budgets you named the same on purpose.
    static var deviceID: String {
        let key = "cloudSync.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Backup before the first sync

    static let backupDoneKey = "cloudSync.preSyncBackupDone"
    static let backupPathKey = "cloudSync.preSyncBackupPath"
    static let pendingRestoreKey = "cloudSync.pendingRestore"

    static let storeFileSuffixes = ["", "-wal", "-shm"]

    /// Copies the store (with its -wal/-shm files) aside once, before the
    /// first launch that syncs, while nothing has it open. If iCloud ever
    /// removes the data (e.g. signing out while uploads were failing), this
    /// copy can be restored from Settings → iCloud sync. Returns false if
    /// the copy failed; the caller then stays local for this launch.
    static func backUpBeforeFirstSync(store: URL, defaults: UserDefaults = .standard, fm: FileManager = .default, now: Date = .now) -> Bool {
        if defaults.bool(forKey: backupDoneKey) { return true }
        guard fm.fileExists(atPath: store.path) else {
            defaults.set(true, forKey: backupDoneKey)   // nothing to back up
            return true
        }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let dir = store.deletingLastPathComponent().appending(path: "PreSyncBackup").appending(path: stamp)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in storeFileSuffixes {
                let source = URL(fileURLWithPath: store.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: dir.appending(path: store.lastPathComponent + suffix))
            }
            defaults.set(dir.path, forKey: backupPathKey)
            defaults.set(true, forKey: backupDoneKey)
            return true
        } catch {
            try? fm.removeItem(at: dir)
            return false
        }
    }

    /// The pre-sync backup, if one was made and still exists.
    static func backupFolder(defaults: UserDefaults = .standard, fm: FileManager = .default) -> URL? {
        guard let path = defaults.string(forKey: backupPathKey), fm.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Replaces the store with the backup. Only call before any container
    /// has opened the store (i.e. at launch). Sync is turned off so the
    /// restored copy isn't mixed with what's in iCloud.
    static func restoreIfRequested(store: URL, defaults: UserDefaults = .standard, fm: FileManager = .default) {
        guard let path = defaults.string(forKey: pendingRestoreKey) else { return }
        defaults.removeObject(forKey: pendingRestoreKey)
        let backup = URL(fileURLWithPath: path)
        let backupStore = backup.appending(path: store.lastPathComponent)
        guard fm.fileExists(atPath: backupStore.path) else { return }
        do {
            for suffix in storeFileSuffixes {
                let target = URL(fileURLWithPath: store.path + suffix)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            }
            for suffix in storeFileSuffixes {
                let source = URL(fileURLWithPath: backupStore.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: URL(fileURLWithPath: store.path + suffix))
            }
            defaults.set(false, forKey: enabledKey)
            restoredFromBackup = true
        } catch {
            launchError = "Couldn't restore the backup: \(error.localizedDescription)"
        }
    }

    nonisolated(unsafe) static var restoredFromBackup = false

    /// Which container to sync with, or nil to keep everything on this phone.
    static func syncContainer(containerID: String?, userWantsSync: Bool) -> String? {
        userWantsSync ? containerID : nil
    }

    /// What the running store actually syncs with (decided once at launch).
    nonisolated(unsafe) static var activeContainerID: String?
    /// Why sync couldn't start at launch, if it couldn't.
    nonisolated(unsafe) static var launchError: String?
}

/// Live sync status for Settings, from the events SwiftData's CloudKit
/// mirroring posts. Also merges duplicates after each download.
@MainActor
@Observable
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    enum Account: Equatable {
        case unknown, available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine
    }

    var account: Account = .unknown
    var lastSuccess: Date?
    var lastError: String?
    var inProgress = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    func start(container: ModelContainer) {
        guard observers.isEmpty, CloudSync.activeContainerID != nil else { return }
        let events = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let finished = event.endDate != nil
            let succeeded = event.succeeded
            let isImport = event.type == .import
            let message = event.error.map(CloudSyncMonitor.describe)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inProgress = !finished
                guard finished else { return }
                if succeeded {
                    self.lastSuccess = .now
                    self.lastError = nil
                    // Merging deletes records; do it when the UI isn't
                    // showing them (app backgrounded, or next launch).
                    if isImport { SyncDeduplicator.needsRun = true }
                } else if let message {
                    self.lastError = message
                }
            }
        }
        let account = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAccount() }
        }
        observers = [events, account]
        Task { await refreshAccount() }
    }

    func refreshAccount() async {
        guard let id = CloudSync.activeContainerID else { return }
        do {
            switch try await CKContainer(identifier: id).accountStatus() {
            case .available: account = .available
            case .noAccount: account = .noAccount
            case .restricted: account = .restricted
            case .temporarilyUnavailable: account = .temporarilyUnavailable
            default: account = .couldNotDetermine
            }
        } catch {
            account = .couldNotDetermine
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .networkUnavailable, .networkFailure: return "No internet connection. It will sync when you're back online."
            case .quotaExceeded: return "Your iCloud storage is full. Free up space in iCloud settings."
            case .notAuthenticated: return "Sign in to iCloud in the Settings app to sync."
            case .requestRateLimited, .zoneBusy, .serviceUnavailable: return "iCloud is busy. It will try again shortly."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// Two phones can each create the same thing before they've synced, e.g.
/// both close November, or you add "Food" on a new phone before your data
/// arrives. This merges those duplicates. Every phone picks the same record
/// to keep, so they agree without talking to each other. It runs after
/// iCloud downloads, while the app isn't on screen (backgrounded or at the
/// next launch), so nothing visible disappears underneath you.
///
/// It never merges what one phone made on purpose: budgets are only merged
/// when they came from different installs, and payments are never deleted.
enum SyncDeduplicator {
    struct Report: Equatable {
        var budgets = 0
        var paymentsMoved = 0
        var monthCloses = 0
        var contributions = 0
        var savingsAccounts = 0
        var total: Int { budgets + paymentsMoved + monthCloses + contributions + savingsAccounts }
    }

    static let needsRunKey = "cloudSync.needsDedupe"
    /// Set after an iCloud download; cleared once merged.
    static var needsRun: Bool {
        get { UserDefaults.standard.bool(forKey: needsRunKey) }
        set { UserDefaults.standard.set(newValue, forKey: needsRunKey) }
    }

    /// Runs if a download happened since the last run.
    @discardableResult
    static func runIfNeeded(in context: ModelContext) -> Report? {
        guard needsRun else { return nil }
        needsRun = false
        return run(in: context)
    }

    @discardableResult
    static func run(in context: ModelContext) -> Report {
        var report = Report()
        report.budgets = mergeBudgets(in: context)
        report.paymentsMoved = movePaymentsOffMergedBudgets(in: context)
        report.monthCloses = mergeMonthCloses(in: context)
        report.contributions = mergeContributions(in: context)
        report.savingsAccounts = mergeSavingsAccounts(in: context)
        if report.total > 0 { try? context.save() }
        return report
    }

    /// Same name (ignoring case, accents and spaces), both active, made by
    /// different installs: the first-made one stays and the other's payments
    /// move into it. The other is archived with `mergedIntoID` (not deleted),
    /// so payments still on their way to it from iCloud can follow later.
    /// Budgets made before sync existed (no origin) count as one install.
    static func mergeBudgets(in context: ModelContext) -> Int {
        let active = ((try? context.fetch(FetchDescriptor<Budget>())) ?? [])
            .filter { $0.archivedAt == nil && $0.mergedIntoID == nil }
        let groups = Dictionary(grouping: active) { normalizedName($0.name) }
        var merged = 0
        for (key, group) in groups where !key.isEmpty && group.count > 1 {
            let sorted = group.sorted { ($0.insertedAt, $0.id.uuidString) < ($1.insertedAt, $1.id.uuidString) }
            let keep = sorted[0]
            for duplicate in sorted.dropFirst() where duplicate.originDevice != keep.originDevice {
                for payment in duplicate.payments ?? [] { payment.budget = keep }
                if keep.colorName.isEmpty { keep.colorName = duplicate.colorName }
                if let armed = duplicate.armedAt, armed > (keep.armedAt ?? .distantPast) { keep.armedAt = armed }
                keep.createdAt = min(keep.createdAt, duplicate.createdAt)   // past months still add up
                duplicate.armedAt = nil
                duplicate.mergedIntoID = keep.id
                duplicate.archivedAt = duplicate.archivedAt ?? .now
                merged += 1
            }
        }
        return merged
    }

    /// Payments that synced in pointing at a merged duplicate follow it.
    static func movePaymentsOffMergedBudgets(in context: ModelContext) -> Int {
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        let byID = Dictionary(budgets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved = 0
        for duplicate in budgets {
            guard var targetID = duplicate.mergedIntoID else { continue }
            // Follow chains (A merged into B, B into C), with a loop guard.
            var hops = 0
            while let next = byID[targetID]?.mergedIntoID, hops < 10 { targetID = next; hops += 1 }
            guard let target = byID[targetID], target !== duplicate else { continue }
            for payment in duplicate.payments ?? [] {
                payment.budget = target
                moved += 1
            }
        }
        return moved
    }

    /// One close per month: keep the first one made (a second close of the
    /// same month is refused on a single phone, too).
    static func mergeMonthCloses(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<MonthClose>())) ?? []
        var removed = 0
        for (_, group) in Dictionary(grouping: all, by: \.monthKey) where group.count > 1 {
            let sorted = group.sorted {
                ($0.closedAt, -$0.movedCents, $0.linesJSON) < ($1.closedAt, -$1.movedCents, $1.linesJSON)
            }
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    /// One monthly contribution per belonging per month: keep the earliest.
    static func mergeContributions(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<FundEntry>())) ?? []
        let contributions = all.filter { $0.kind == .contribution && $0.monthKey != nil && $0.belonging != nil }
        let groups = Dictionary(grouping: contributions) { entry in
            "\(entry.belonging?.id.uuidString ?? "")|\(entry.monthKey ?? "")"
        }
        var removed = 0
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    /// One savings balance. The newest balance you actually entered or that
    /// was already there wins; an account a phone made from scratch before
    /// its data arrived (provisional) only contributes its adds/subtracts.
    static func mergeSavingsAccounts(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<SavingsAccount>())) ?? []
        guard all.count > 1 else { return 0 }
        let real = all.filter { !$0.isProvisional }
            .sorted { ($0.updatedAt, $0.balanceCents) > ($1.updatedAt, $1.balanceCents) }
        let provisional = all.filter(\.isProvisional)
            .sorted { ($0.updatedAt, $0.deltaCents) < ($1.updatedAt, $1.deltaCents) }
        if let keep = real.first {
            for p in provisional {
                keep.balanceCents += p.deltaCents
                keep.updatedAt = max(keep.updatedAt, p.updatedAt)
                context.delete(p)
            }
            for duplicate in real.dropFirst() { context.delete(duplicate) }
        } else if let keep = provisional.first {
            // Still no real balance anywhere: combine the changes.
            for p in provisional.dropFirst() {
                keep.balanceCents += p.deltaCents
                keep.deltaCents += p.deltaCents
                keep.updatedAt = max(keep.updatedAt, p.updatedAt)
                context.delete(p)
            }
        }
        return all.count - 1
    }

    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

#if DEBUG
/// Developer tool (Debug builds only): creates every record type and field
/// in the CloudKit Development schema in one go, so it can be deployed to
/// Production. Uses a throwaway store; your data isn't touched.
enum CloudKitSchemaInitializer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(containerID: String) throws {
        let url = URL.temporaryDirectory.appending(path: "spaar-schema-\(UUID().uuidString).sqlite")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: Persistence.modelTypes) else {
            throw Failure(message: "Couldn't build the Core Data model from the SwiftData models.")
        }
        let container = NSPersistentCloudKitContainer(name: "SpaarSchema", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        try container.initializeCloudKitSchema()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
