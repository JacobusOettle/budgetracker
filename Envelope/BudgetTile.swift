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

    /// How full the tile is: 1 with the whole month's amount left, 0.5 at
    /// half, 0 when empty or over budget.
    static func fill(leftCents: Int, monthlyCents: Int) -> Double {
        guard monthlyCents > 0 else { return 0 }
        return min(1, max(0, Double(leftCents) / Double(monthlyCents)))  // display only
    }
}

/// A square budget tile, filled with its colour in proportion to what's left.
struct BudgetTile: View {
    let budget: Budget
    let now: Date

    private let corner: CGFloat = 22

    var body: some View {
        let left = budget.leftCents(now: now)
        let fill = BudgetPalette.fill(leftCents: left, monthlyCents: budget.monthlyCents)
        let key = BudgetPalette.key(for: budget)
        let color = BudgetPalette.color(forKey: key)
        let remaining = Arming.remaining(armedAt: budget.armedAt, now: now)
        let armed = remaining > 0
        let warning = BudgetWarning.level(leftCents: left, monthlyCents: budget.monthlyCents)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        ZStack {
            shape.fill(color.opacity(0.15))
            FillLevel(fraction: fill) { Rectangle().fill(color.gradient) }
            // Text on the empty part…
            label(left: left, remaining: remaining, armed: armed)
                .foregroundStyle(warning == .empty ? Color.red : Color.primary)
            // …and the same text in a contrasting colour over the filled part.
            label(left: left, remaining: remaining, armed: armed)
                .foregroundStyle(BudgetPalette.textOnFill(forKey: key))
                .mask(FillLevel(fraction: fill) { Rectangle() })
        }
        .clipShape(shape)
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            shape.strokeBorder(borderColor(armed: armed, warning: warning, color: color), lineWidth: armed ? 4 : 2)
        )
        .shadow(color: armed ? color.opacity(0.5) : .clear, radius: 8)
        .animation(.easeInOut(duration: 0.4), value: fill)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(budget.name), \(Money.format(cents: left)) left of \(Money.format(cents: budget.monthlyCents))\(armed ? ", armed" : "")")
    }

    private func label(left: Int, remaining: TimeInterval, armed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text(budget.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if armed {
                    Label(Arming.countdown(remaining), systemImage: "bolt.fill")
                        .font(.caption.bold().monospacedDigit())
                        .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 0)
            Text(Money.format(cents: left))
                .font(.title2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("left of \(Money.format(cents: budget.monthlyCents))")
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func borderColor(armed: Bool, warning: BudgetWarning, color: Color) -> Color {
        if armed { return .primary }
        switch warning {
        case .empty: return .red
        case .low: return .orange
        case .none: return .clear
        }
    }
}

/// A bottom-aligned block filling `fraction` of the available height.
private struct FillLevel<Content: View>: View {
    let fraction: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                    .frame(height: geo.size.height * fraction)
            }
        }
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
