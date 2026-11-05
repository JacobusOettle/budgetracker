import SwiftUI

/// Colours you can give a budget tile.
enum BudgetPalette {
    static let keys = ["blue", "green", "orange", "purple", "pink", "teal", "red", "indigo", "yellow", "mint", "brown", "gray"]

    static func color(forKey key: String) -> Color {
        switch key {
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "red": .red
        case "indigo": .indigo
        case "yellow": .yellow
        case "mint": .mint
        case "brown": .brown
        case "gray": .gray
        default: .blue
        }
    }

    /// Text colour that stays readable on top of the filled part.
    static func textOnFill(forKey key: String) -> Color {
        ["yellow", "mint"].contains(key) ? .black : .white
    }

    /// Your chosen colour, or one picked from the tile's position.
    static func resolvedKey(colorName: String, sortOrder: Int) -> String {
        keys.contains(colorName) ? colorName : keys[abs(sortOrder) % keys.count]
    }

    static func key(for budget: Budget) -> String {
        resolvedKey(colorName: budget.colorName, sortOrder: budget.sortOrder)
    }

    static func color(for budget: Budget) -> Color { color(forKey: key(for: budget)) }

    /// How full the progress bar is: 1 with the whole month's amount left,
    /// 0.5 at half, 0 when empty or over budget.
    static func fill(leftCents: Int, monthlyCents: Int) -> Double {
        guard monthlyCents > 0 else { return 0 }
        return min(1, max(0, Double(leftCents) / Double(monthlyCents)))  // display only
    }
}

/// Colour picker for the budget form.
struct BudgetColorPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            ForEach(BudgetPalette.keys, id: \.self) { key in
                Button {
                    selection = key
                } label: {
                    Circle()
                        .fill(BudgetPalette.color(forKey: key).gradient)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle().strokeBorder(Color.primary, lineWidth: selection == key ? 3 : 0)
                        )
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(BudgetPalette.textOnFill(forKey: key))
                                .opacity(selection == key ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key)
                .accessibilityAddTraits(selection == key ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
