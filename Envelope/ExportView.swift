import SwiftUI
import SwiftData

struct ExportView: View {
    @Environment(\.modelContext) private var context
    @State private var fileURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("Exports everything in Tally as one JSON file: budgets, payments, month-ends, savings, belongings and replacement funds.")
                Text("It's written to be read by an AI assistant. Amounts are exact rand values, and the file starts with an \"about\" section explaining every field. Attach it to a chat and ask your questions.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Create export file") { prepare() }
                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("Share \(fileURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("The file only leaves your phone if you share it.")
            }
        }
        .navigationTitle("Export")
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepare() {
        do { fileURL = try DataExport.writeFile(context: context) } catch { errorMessage = error.localizedDescription }
    }
}
