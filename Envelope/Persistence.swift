import Foundation
import SwiftData

/// One container shared by the UI and by App Intents. Intents run inside the
/// app process (no extension), so the same on-device store is used either way.
enum Persistence {
    static let schema = Schema([
        DebugPayment.self,
        Budget.self,
        Payment.self,
        MonthClose.self,
        Belonging.self,
        Ownership.self,
        FundEntry.self,
        SavingsAccount.self,
    ])

    /// Syncs with the user's private iCloud database when this build has the
    /// iCloud entitlement and sync is on in Settings; otherwise stays on this
    /// phone. Same store file either way, so turning sync on uploads what's
    /// already there, and turning it off keeps everything on the phone.
    static let shared: ModelContainer = {
        let cloud = CloudSync.syncContainer(containerID: CloudSync.containerID, userWantsSync: CloudSync.userWantsSync)
        if let cloud {
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
