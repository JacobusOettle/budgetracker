import Foundation
import SwiftData

/// One container shared by the UI and by App Intents. Intents run inside the
/// app process (no extension), so the same on-device store is used either way.
enum Persistence {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: DebugPayment.self)
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }
    }()
}
