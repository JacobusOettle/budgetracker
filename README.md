# Envelope (spike)

Envelope is an iPhone budgeting app. You tap a budget before paying with Apple Pay,
and an iOS Shortcuts **Transaction** automation tells Envelope about the payment.
It never connects to a bank, and all data stays on the phone.

**Current state: build step 1, the spike.** This build only proves that the
Transaction automation can call Envelope's App Intent in the background and pass
the amount, merchant and card. Each payment it receives goes into a debug list.
There are no budgets, arming or deductions yet. Those come once the spike works
on your phone.

## What's in the spike

| Piece | File |
|---|---|
| App Intent **Log Payment** (amount as text, parsed by us) | `Envelope/LogPaymentIntents.swift` |
| App Intent **Log Payment (Currency Amount)** (amount as a typed currency value) | `Envelope/LogPaymentIntents.swift` |
| Amount parser (`R 1 234,56`, `R1,234.56`, `ZAR 99.99`…) → integer cents | `Envelope/AmountParser.swift` |
| Money helpers (Decimal → cents, half-away-from-zero rounding, `R1 234.56` formatting) | `Envelope/Money.swift` |
| SwiftData debug log, flags (doesn't drop) repeats within 2 minutes | `Envelope/PaymentLogger.swift`, `Envelope/DebugPayment.swift` |
| Debug list screen with Simulate, Share log and Clear | `Envelope/DebugPaymentListView.swift` |
| Unit tests | `EnvelopeTests/` |

There are two intents on purpose. Developers report that the way Shortcut Input
maps to intent parameters, especially *Amount*, is unreliable. The text variant
takes whatever Shortcuts sends and parses it. The currency variant shows whether
the typed mapping works. You add both to the same automation, and each logs its
own row, tagged `text` or `currency`.

Both intents set `openAppWhenRun = false`, so they should work with **Run Immediately**
without opening the app. Each one posts a local notification
("Envelope logged…") so you can see at the till that it ran.

## Belongings: saving to replace things

The **Belongings** tab keeps your *replacement savings* separate from your
*true savings*.

- **Add something you own:** name, category, date bought, price, and optionally
  what the next one will cost and how much you've already saved for it.
- **How long it will last** is decided in this order:
  1. **Your own estimate**, if you set one ("Set my own lifespan").
  2. **How long your last one lasted**, if you've owned one before. You can
     enter this when adding the item. When you replace something in the app, the
     months it actually lasted are filled in for the next one automatically.
  3. **A typical lifespan for the category**, for example 3 years for a phone or
     12 years for a fridge. These are rough estimates built into the app (see
     `Envelope/BelongingCategory.swift`), not real population statistics. The app
     has no internet access, so it can't look anything up.
- **Monthly amount** = (target − already saved) ÷ months left, rounded **up** to
  the cent. A new R24 000 phone that should last 4 years is R500/month. If you add
  an item halfway through its life, or the fund falls behind, it catches up over
  the time that's left.
- **Each month**, tap **Record November contributions**. Envelope can't move money,
  so you make the transfer in your banking app and then confirm. You can record a
  month only once.
- **Outlasting its expected life:** once an item reaches its expected date fully
  funded, contributions stop. Everything you save after that counts as true savings.
- **Replacing it:** the fund pays for the new one.
  - **Cheaper than the fund?** The leftover moves to true savings.
  - **Dearer, or it broke early?** The shortfall comes out of true savings. Either
    buy a cheaper one or use savings.
  - **Got rid of it without replacing?** Its whole fund moves to true savings.
- **True savings** = your total savings balance (which you type in from your
  banking app) − everything set aside for replacements. If it goes negative, the
  app warns you that the replacement funds aren't fully backed.

## Export for AI analysis

The **Export** tab creates one file, `envelope-export-YYYY-MM-DD.json`, holding
everything: your savings split, belongings, each fund's history, ownership history
and logged payments. JSON was chosen because AI assistants read it reliably:

- The file starts with an `"about"` section that explains every section and field
  in plain English.
- Money is stored as exact rand strings (`"24000.00"`), never as rounded floats.
- Derived values are included, such as the monthly contribution, months left,
  plan status and how long past items lasted. An AI doesn't have to recalculate them.

Share it (AirDrop, Files, a chat app) and attach it to any AI assistant. The file
only leaves your phone when you share it.

## Testing the spike on your iPhone (FNB and Capitec)

### 0. Requirements
- An iPhone on iOS 17 or later, with your FNB and Capitec cards added to Apple Wallet.
- Envelope installed (see [Installing](#installing-on-your-iphone) below).

### 1. Check the app logs anything at all
1. Open Envelope and **allow notifications** when asked.
2. Tap **Simulate → Simulate text payment**. A row `R1 234.56 · Test Merchant` appears
   along with a banner.
3. Tap **Simulate → Simulate currency payment**. A row `R42.50` appears.
4. Swipe the rows away, or use **Simulate → Clear all**.

### 2. Create the Wallet automation (iOS 26)
On iOS 26 the trigger is called **Wallet**. Older iOS versions and guides call it
**Transaction**.

1. Open **Shortcuts** and tap **Automation** at the bottom.
2. Tap **+** (top right), or **New Automation** if you have none yet.
3. Scroll the trigger list and tap **Wallet**.
4. Under **When I tap**, select your **FNB** and **Capitec** cards.
5. Under **Category**, untick **Transport**. Leave **Merchant** empty.
6. At the bottom, select **Run Immediately** (not "Run After Confirmation"). Tap **Next**.
7. Tap **New Blank Automation** (some versions say **Create New Shortcut**).
8. In the search bar at the bottom, type **Envelope** and tap **Log Payment**. The
   action reads: *Log* **Amount** *at* **Merchant**.
9. Connect the fields:
   1. Tap the faded word **Amount** in the action.
   2. A row of suggestions appears above the keyboard. Swipe it sideways and tap
      **Shortcut Input**.
   3. The field now shows a blue **Shortcut Input** bubble. Tap the bubble, and from
      the list choose **Amount**. The bubble should now say *Amount*.
   4. Do the same for **Merchant**, choosing **Merchant**.
   5. Tap the small **›** arrow on the right of the action to show **Card** and
      **Raw Input**. Set Card the same way, choosing **Card or Pass**. For Raw
      Input, pick **Shortcut Input** and **don't** choose a property.
10. Optional: search **Envelope** again, add **Log Payment (Currency Amount)** and
    connect it the same way. If it won't accept *Amount*, delete it and tell me.
11. Tap **Done** (top right).

Don't test with the ▶︎ play button in Shortcuts. It sends no payment data, so every
field arrives empty. Only a real tap at a card machine counts.

### 3. Pay for real
Make a small Apple Pay purchase **with each card**. A few rand is fine, for example
a coffee or parking. After each one:
- Did an "Envelope logged…" notification appear? How long after paying?
- Did Shortcuts show any "Allow Envelope…?" prompt? If you tapped **Always Allow**,
  did it ask again on the next payment?
- Open Envelope. Is there one row per action (`text` and `currency`)? Is the amount
  right to the cent? Are the merchant and card names filled in?
- Are there any rows marked **DUPLICATE?**? That would mean the automation fired twice.

Also try **one payment with the iPhone locked** and **one right after force-quitting
Envelope** from the app switcher. That checks the intent really runs in the background.

### 4. Send me the results
In Envelope, tap **Share log** (top left) and paste the text into our chat. It holds
the raw amount string exactly as Shortcuts sent it, which is what decides the
amount parsing for the real app. Also tell me what you saw for each question in
step 3.

> The Transaction trigger only fires on real NFC payments on a physical iPhone.
> It can't be tested in the simulator or in CI.

## Installing on your iPhone

Every app on an iPhone has to be signed by an Apple ID. Pick one option:

### Option A: You have a Mac (simplest)
1. Install Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   `brew install xcodegen`.
2. `git clone` this repo, then `cd budgetracker && xcodegen generate && open Envelope.xcodeproj`.
3. Select the **Envelope** target → **Signing & Capabilities** → choose your Team.
   A free Apple ID works. If Xcode says the bundle ID is taken, change
   `com.jacobusoettle.envelope` to something unique.
4. Plug in your iPhone. On the phone, enable **Settings → Privacy & Security →
   Developer Mode** and restart.
5. Pick the iPhone as the run destination and press **Run** (⌘R).
6. The first time, trust the developer on the phone: **Settings → General →
   VPN & Device Management**.

With a free Apple ID the app stops launching after **7 days**. Just run it from
Xcode again. A paid Apple Developer account ($99/yr) gives you a year.

### Option B: No Mac. Use the CI-built unsigned IPA plus Sideloadly (Windows or Mac)
1. On GitHub, open **Actions → iOS build**, open the latest green run, and download
   the **Envelope-ipa** artifact. Unzip it to get `Envelope-unsigned.ipa`.
2. Install [Sideloadly](https://sideloadly.io) on a Windows PC or Mac. On Windows
   it also needs iTunes and iCloud from Apple's site, not the Microsoft Store.
3. Connect the iPhone by USB, drag the IPA into Sideloadly, enter your Apple ID,
   and click **Start**. Sideloadly signs it with your Apple ID and installs it.
4. Enable **Developer Mode** and trust the developer profile as in Option A, steps 4 and 6.

The free-Apple-ID 7-day limit applies here too. AltStore is an alternative that
re-signs automatically.

### Option C: Paid developer account, signed IPA from CI
Add these **repository secrets** (Settings → Secrets and variables → Actions)
and CI will also produce `Envelope-signed.ipa`:

| Secret | What |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Your *Apple Development* (or *Apple Distribution* for ad-hoc) certificate exported from Keychain as `.p12`, then `base64 -i cert.p12` |
| `P12_PASSWORD` | Password you set when exporting the `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | A Development or Ad Hoc provisioning profile for `com.jacobusoettle.envelope` that includes your iPhone's UDID, as `base64 -i profile.mobileprovision` |

Optional repository **variable** `EXPORT_METHOD`: `development` (the default) or
`ad-hoc`. A wildcard profile works too. The bundle ID is read from the profile.
Install the signed IPA with Apple Configurator, Sideloadly, Xcode's Devices window,
or Finder (drag it onto the phone).

## CI

`.github/workflows/ios.yml` runs on every push, on a `macos-15` runner:
1. Generates `Envelope.xcodeproj` from `project.yml` with XcodeGen. The project
   file isn't committed.
2. Runs the unit tests on an iPhone simulator.
3. Builds an unsigned Release `.ipa` and checks that the App Intents metadata is
   in the bundle. Without it, the actions wouldn't appear in Shortcuts.
4. If the signing secrets exist, archives and exports a signed `.ipa`.
5. Uploads the IPA(s) as the `Envelope-ipa` artifact and the test results as `test-results`.

## Project layout and conventions
- Swift, SwiftUI, SwiftData and App Intents. Deployment target is **iOS 17.0**,
  the minimum for the Transaction automation trigger.
- Money is stored as **integer cents**. Fractions are only handled as `Decimal`,
  never `Double`. Rounding is half away from zero. The default currency is ZAR.
- No backend, accounts, analytics or bank credentials.

## Next steps (after the spike is confirmed)
The belongings, replacement funds and export are built. They don't depend on the
Shortcuts trigger. Still waiting on spike confirmation:
Data model and arming logic (10-minute expiry, idempotent logging, Unassigned
payments and notifications), then the budget UI, transaction history, manual entry,
the missed-payment reminder, the month-end screen and an in-app Shortcuts setup guide.
