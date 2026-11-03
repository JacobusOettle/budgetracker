import SwiftUI

/// Text field for a rand amount. Parsed with AmountParser into cents.
struct MoneyField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("R").foregroundStyle(.secondary)
            TextField("0.00", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
        }
    }

    static func cents(_ text: String) -> Int? {
        guard let parsed = AmountParser.parse(text), parsed.cents >= 0 else { return nil }
        return parsed.cents
    }

    static func text(_ cents: Int?) -> String {
        guard let cents else { return "" }
        return Money.plain(cents: cents)
    }
}

/// Picks a period as years + months.
struct LifespanEditor: View {
    @Binding var months: Int

    var body: some View {
        Stepper(value: Binding(
            get: { months / 12 },
            set: { months = max(0, $0) * 12 + months % 12 }
        ), in: 0...40) {
            LabeledContent("Years", value: "\(months / 12)")
        }
        Stepper(value: Binding(
            get: { months % 12 },
            set: { months = (months / 12) * 12 + min(11, max(0, $0)) }
        ), in: 0...11) {
            LabeledContent("Months", value: "\(months % 12)")
        }
    }
}
