import Foundation
import SwiftData

/// One container shared by the UI and by App Intents. Intents run inside the
/// app process (no extension), so the same on-device store is used either way.
enum Persistence {
    static let schema = Schema([
        DebugPayment.self,
        Belonging.self,
        Ownership.self,
        FundEntry.self,
        SavingsAccount.self,
    ])

    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }
    }()

    static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
