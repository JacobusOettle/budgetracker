import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            BelongingsView()
                .tabItem { Label("Belongings", systemImage: "shippingbox") }
            DebugPaymentListView()
                .tabItem { Label("Payments", systemImage: "creditcard") }
            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
    }
}
