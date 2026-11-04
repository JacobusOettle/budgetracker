import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            BudgetsHomeView()
                .tabItem { Label("Budgets", systemImage: "envelope") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
            BelongingsView()
                .tabItem { Label("Belongings", systemImage: "shippingbox") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Identifies a month for sheets.
struct MonthTarget: Identifiable {
    let start: Date
    var id: Date { start }
}
