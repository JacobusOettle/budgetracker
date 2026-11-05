import SwiftUI

/// Picture-by-picture guide for creating the Wallet automation in Shortcuts.
/// The pictures are drawings of the iOS 26 Shortcuts screens with the thing
/// to tap ringed in orange and numbered.
struct SetupWalkthroughView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page = 0

    struct Step {
        let image: String
        let title: String
        let detail: LocalizedStringKey
    }

    static let steps: [Step] = [
        Step(image: "SetupStep1", title: "Open Automation",
             detail: "Open **Shortcuts**, tap **Automation** at the bottom, then tap **+** at the top right."),
        Step(image: "SetupStep2", title: "Choose Wallet",
             detail: "Scroll the list and tap **Wallet**. On older iOS it's called **Transaction**."),
        Step(image: "SetupStep3", title: "Any card, run immediately",
             detail: "Set **Card** to **Any Card**. Leave categories and merchant as they are. Choose **Run Immediately**, then tap **Next**."),
        Step(image: "SetupStep4", title: "Start blank",
             detail: "Tap **New Blank Automation**."),
        Step(image: "SetupStep5", title: "Add Spaar's action",
             detail: "In the search bar at the bottom, type **Spaar**, then tap **Log Payment**."),
        Step(image: "SetupStep6", title: "Fill in the amount",
             detail: "Tap the faded **Amount**. Above the keyboard, tap **Shortcut Input**."),
        Step(image: "SetupStep7", title: "Pick “Amount”",
             detail: "Tap the blue **Shortcut Input** bubble and choose **Amount** from the list."),
        Step(image: "SetupStep8", title: "Fill in the merchant",
             detail: "Do the same for the second field: tap **Merchant** → **Shortcut Input** → tap the bubble → **Merchant**. It must say Merchant, not Amount."),
        Step(image: "SetupStep9", title: "Card, and turn off Show When Run",
             detail: "Tap the circled **›** at the end of the action. Set **Card** the same way, choosing **Card or Pass**. Leave **Raw Input** empty and switch **Show When Run** off."),
        Step(image: "SetupStep10", title: "Save",
             detail: "Tap **‹** at the top left to save. Your next Apple Pay tap appears in Spaar, and the setup screen will say **Working**."),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        ScrollView {
                            VStack(spacing: 14) {
                                Image(step.image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 460)
                                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                                    .accessibilityLabel("Picture of step \(index + 1): \(step.title)")
                                Text("Step \(index + 1) of \(Self.steps.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(step.title)
                                    .font(.title3.bold())
                                Text(step.detail)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                HStack {
                    Button("Back") { withAnimation { page = max(0, page - 1) } }
                        .disabled(page == 0)
                    Spacer()
                    Button {
                        openURL(URL(string: "shortcuts://")!)
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    if page < Self.steps.count - 1 {
                        Button("Next") { withAnimation { page += 1 } }
                    } else {
                        Button("Done") { dismiss() }.bold()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Set up step by step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}
