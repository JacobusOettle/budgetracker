import Foundation
import SwiftData

/// One container shared by the UI and by App Intents. Intents run inside the
/// app process (no extension), so the same on-device store is used either way.
enum Persistence {
    static let modelTypes: [any PersistentModel.Type] = [
        DebugPayment.self,
        Budget.self,
        Payment.self,
        MonthClose.self,
        Belonging.self,
        Ownership.self,
        FundEntry.self,
        SavingsAccount.self,
    ]

    static let schema = Schema(modelTypes)

    /// Where SwiftData keeps the default store.
    static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }

    /// Syncs with the user's private iCloud database when this build has the
    /// iCloud entitlement and sync is on in Settings; otherwise stays on this
    /// phone. Same store file either way, so turning sync on uploads what's
    /// already there, and turning it off keeps everything on the phone.
    static let shared: ModelContainer = {
        let store = storeURL
        CloudSync.restoreIfRequested(store: store)
        CloudSync.decideDefault(storeExists: FileManager.default.fileExists(atPath: store.path))
        let cloud = CloudSync.syncContainer(containerID: CloudSync.containerID, userWantsSync: CloudSync.userWantsSync)
        if cloud != nil, !CloudSync.backUpBeforeFirstSync(store: store) {
            CloudSync.launchError = "Couldn't make a backup before the first sync, so sync stays off for now. Free up space on your iPhone and reopen Spaar."
        } else if let cloud {
            do {
                let container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloud))
                )
                CloudSync.activeContainerID = cloud
                return container
            } catch {
                // Never lose access to the data over sync: fall back to local.
                CloudSync.launchError = error.localizedDescription
            }
        }
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }
    }()

    static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
