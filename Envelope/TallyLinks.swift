import Foundation

enum TallyLinks {
    /// iCloud link to the shared "Log to Tally" shortcut, which passes a
    /// Wallet transaction's amount, merchant and card to Tally's Log Payment
    /// action. With it, setup is: add the shortcut, then create a Wallet
    /// automation that runs it. Without it (nil), the by-hand steps are shown.
    ///
    /// To make it: in Shortcuts create a shortcut named "Log to Tally" with
    /// Tally's Log Payment action (Amount/Merchant/Card from Shortcut Input),
    /// then Share → Copy iCloud Link, and paste the link here.
    static let logPaymentShortcut: URL? = nil
}
