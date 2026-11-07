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

    /// The user's choice in Settings. On by default. Applied at launch.
    static var userWantsSync: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

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
                    if isImport { SyncDeduplicator.run(in: container.mainContext) }
                } else if let message {
                    self.lastError = message
                }
            }
        }
        let account = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshAccount() } }
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
/// to keep, so they agree without talking to each other. Payments are never
/// deleted: a duplicate budget's payments move to the one that's kept.
enum SyncDeduplicator {
    struct Report: Equatable {
        var budgets = 0
        var monthCloses = 0
        var contributions = 0
        var savingsAccounts = 0
        var total: Int { budgets + monthCloses + contributions + savingsAccounts }
    }

    @discardableResult
    static func run(in context: ModelContext) -> Report {
        var report = Report()
        report.budgets = mergeBudgets(in: context)
        report.monthCloses = mergeMonthCloses(in: context)
        report.contributions = mergeContributions(in: context)
        report.savingsAccounts = mergeSavingsAccounts(in: context)
        if report.total > 0 { try? context.save() }
        return report
    }

    /// Same name (ignoring case, accents and spaces), both active: keep the
    /// oldest, move the other's payments into it.
    static func mergeBudgets(in context: ModelContext) -> Int {
        let active = ((try? context.fetch(FetchDescriptor<Budget>())) ?? []).filter { $0.archivedAt == nil }
        let groups = Dictionary(grouping: active) { normalizedName($0.name) }
        var removed = 0
        for (key, group) in groups where !key.isEmpty && group.count > 1 {
            let sorted = group.sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
            let keep = sorted[0]
            for duplicate in sorted.dropFirst() {
                for payment in duplicate.payments ?? [] { payment.budget = keep }
                if keep.colorName.isEmpty { keep.colorName = duplicate.colorName }
                if let armed = duplicate.armedAt, armed > (keep.armedAt ?? .distantPast) { keep.armedAt = armed }
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
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

    /// There is one savings balance: keep the most recently updated.
    static func mergeSavingsAccounts(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<SavingsAccount>())) ?? []
        guard all.count > 1 else { return 0 }
        let sorted = all.sorted {
            ($0.updatedAt, $0.balanceCents) > ($1.updatedAt, $1.balanceCents)
        }
        for duplicate in sorted.dropFirst() { context.delete(duplicate) }
        return all.count - 1
    }

    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
