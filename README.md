# Tally

Tally is an iPhone budgeting app for rand. Tap a budget, such as Food, just
before you pay with Apple Pay. An iOS Shortcuts **Wallet** automation then tells
Tally about the payment, and it's logged to that budget. Tally never connects
to a bank, has no account or analytics, and all data stays on the phone.

> **About the name.** The app is called **Tally** on your home screen, in Shortcuts and in
> notifications. Inside the code, the Xcode project, folders and bundle ID
> (`com.jacobusoettle.envelope`) keep the old working name "Envelope", so your data and
> your existing Shortcuts automation carry on working after an update.

## Using Tally

**Budgets tab (home)**
- Each budget shows **what's left this month** in rand. The amount turns orange
  when 20% or less is left and red when it's empty or over budget.
- **Tap a budget to arm it.** It stays armed for **10 minutes**, with a countdown,
  or until a payment arrives. Tap it again to disarm. Arming one budget disarms
  the others.
- If the armed budget is low or empty, the card says so clearly. **Envelope can't
  block a payment**, and the app never implies it can.
- The **+** menu has New budget, Add a payment and Month end. **Long-press** a
  budget to edit it, see its payments or remove it. A removed budget with payments
  is archived, so history and past months still add up.

**When a payment arrives** (from the automation):
1. **Armed budget:** the payment is logged there and the budget disarms. You get a
   notification like "R100.70 → Food, R2 899.30 left".
2. **Nothing armed:** it's saved as **Unassigned** and you get a notification
   asking you to assign it. The home screen shows a "to sort out" banner.
3. **The same amount, merchant and card again within 2 minutes:** ignored. A
   repeated Shortcut run can't deduct twice. The catch is that two genuinely
   identical taps that close together count once, so add the second one by hand.
4. **Unreadable amount, or not in rand:** it's saved and flagged for you to check.

**History tab:** every payment, grouped by month, with the ones to sort out at the
top. Tap a payment to edit or reassign it, swipe to delete, long-press to assign
quickly. Use **+** for online purchases and missed payments.

**Month end:** shows what each budget has left, the unassigned spending, and the
**total to move to savings**. Overspending in one budget eats into the others,
unassigned spending is taken off, and the total is never negative. If you track
belongings, it also shows how much of that goes to replacement funds and how much
is true savings. Envelope can't move money, so you transfer it in your banking
app, enter what you moved and confirm. Your savings balance goes up by that
amount, that month's replacement contributions are recorded, and budgets start
fresh with the new calendar month. Closing a month twice does nothing. A banner on
the home screen reminds you of any past month you haven't closed.

**Settings:** AI categorisation, the Shortcuts setup guide, **Send a test payment** (runs the real
payment path with R12.34), the daily **missed-payment reminder** (on by default at
20:00), and export.

## AI categorisation (optional)

**Settings → Auto-categorise with AI.** When a payment arrives and no budget is armed,
Tally can ask an AI model which budget it belongs to.

- **Works with any provider.** Presets cover Claude (Anthropic), OpenAI, OpenRouter
  (any model), Google Gemini and Ollama or LM Studio on your own computer, plus a custom
  option for anything that speaks the OpenAI `/chat/completions` format. Claude uses
  the Anthropic Messages API (`anthropic-version: 2026-10-21`). The default model is
  `claude-opus-5-5`, run at low effort with structured JSON output. You can change the
  model to anything, for example `claude-haiku-5-5` to keep costs down.
- **The key is stored in the iPhone Keychain** and only sent to the provider's address
  you entered. It stays readable while the phone is locked, so background payments can
  still be sorted.
- **It learns from your history.** Each request includes your budgets with what's
  left, up to 80 of your recent payments that *you* sorted (armed, picked or confirmed),
  and every correction you made to an earlier AI guess. Unchecked AI guesses are not fed
  back as truth. Card names, savings and belongings are never sent.
- **It's always visible.** AI-sorted payments show a purple **Auto** badge, with the
  reason, in History. Tap **Looks right** to confirm (the badge becomes **Auto ✓**), or
  pick another budget to correct it. The correction is recorded and sent as a lesson
  next time.
- **It's safe when unsure.** If the model is below 60% confident, picks nothing, times
  out or fails, the payment stays Unassigned. It's saved first, so nothing is lost.
  Payments it couldn't reach are retried when you open the app. "To sort out" also has
  an **Auto-sort unassigned with AI** button.
- **Privacy:** turning this on means the merchant, amount, time, your budget names and
  your recent history leave the phone for the provider you chose.

## Importing a bank statement (CSV)

**Settings → Import bank statement**, or **+ → Import bank statement** on the Budgets
tab. This loads your past spending and lets the AI set up budgets. It needs AI
categorisation set up.

1. In FNB or Capitec online banking, download your transaction history as **CSV**
   (not PDF). You can pick several files, for example one per account or per year.
   The limit is 6 000 rows per file.
2. Tally sends the CSV to your AI provider in parts of 120 rows, with the header
   repeated in each part, asking it to **extract the transactions**. For each one it
   returns the date, a cleaned-up merchant name, the amount, the kind (spend, income,
   transfer or refund) and a spending category. If a part's answer is cut off or
   unreadable, the part is split in half and retried. Rate limits and dropped
   connections are retried with a back-off.
3. A second request sends a summary of spending per category (totals, monthly
   averages, top merchants) and asks for **4–10 budgets** with monthly amounts. It
   reuses the names of budgets you already have.
4. **You review it.** You see the period, how many spending payments were found and
   what was skipped. You can edit each budget's monthly amount or switch a budget
   off. Nothing is saved until you tap **Import**.
5. **What gets imported:**
   - **Spending only.** Income, transfers between your own accounts and refunds are
     skipped.
   - **Duplicates are handled.** Each payment Tally already has cancels out one
     statement row on the same day for the same amount, so re-importing is safe.
     Rows repeated across overlapping files count once, but identical purchases in
     one statement are all kept.
   - **Marking and dates.** Imported payments are marked **Imported** and can be
     reassigned in History, and corrections teach the AI. New budgets start in the
     month of their first imported payment, so past months add up.
   - **Month End.** It still only reminds you about months from when you started
     using Tally.
   - **Unmatched payments.** Payments that fit no budget are only imported, as
     Unassigned, if you choose that.

**Privacy:** the whole file goes to your AI provider, including descriptions,
balances and anything else in it, such as an account number. Keep Tally open while
it runs. Closing the screen stops it.

Apple Wallet's own history can't be imported. Apple doesn't give apps access to it
for FNB or Capitec cards. FinanceKit only covers Apple Card, Cash and Savings, isn't
available in South Africa, and needs Apple's approval.

## Spike results (4 Nov 2026, iPhone on iOS 26, FNB virtual card)

- **Amount arrives as text**, for example `"R 100.70"`. It's parsed to cents
  correctly. Envelope therefore uses a text parameter for Amount.
- **Merchant and card name arrive intact**, for example "KFC Wierda Park" and
  "New FNB Fusion Virtual Premier25".
- **It runs in the background with the phone locked** (Run Immediately), and
  arrives at the same moment as FNB's own SMS.
- **The typed "Currency Amount" parameter failed** with "Couldn't communicate with
  a helper application". That action was removed. If you added it during testing,
  delete it from the automation.
- The confirmation popup that appeared after a payment is gone. The action no
  longer returns a dialog, so only the notification shows.
- **Not yet tested:** the Capitec card, whether "Always Allow" prompts come back,
  and a run after force-quitting the app.

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

## Setting up the Apple Pay automation

The same steps are in the app under **Settings → Shortcuts setup guide**.

### Create the Wallet automation (iOS 26)
On iOS 26 the trigger is called **Wallet**. Older iOS versions and guides call it
**Transaction**.

1. Open **Shortcuts** and tap **Automation** at the bottom.
2. Tap **+** (top right), or **New Automation** if you have none yet.
3. Scroll the trigger list and tap **Wallet**.
4. Under **When I tap**, select your **FNB** and **Capitec** cards.
5. Leave every **Category** ticked, including **Transport**, which likely covers
   fuel, parking and Uber. Leave **Merchant** empty.
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
   5. Tap the small **›** arrow on the right of the action to show **Card**. Set it
      the same way, choosing **Card or Pass**. Leave **Raw Input** empty (it's no
      longer used), and switch **Show When Run** off.
10. Tap **‹** at the top left to save.

Don't test with the ▶︎ play button in Shortcuts. It sends no payment data, so every
field arrives empty. Only a real tap at a card machine counts.

### Limits of the automation
- Online and in-app purchases don't trigger it. Add them under History → +.
- iOS can occasionally miss or delay a payment. The daily reminder covers this.
- A declined tap may still be logged. Delete it in History.
- It can only be tested with real taps on a physical iPhone. The ▶︎ button in
  Shortcuts sends empty fields.

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

## What isn't verified
The unit tests cover arming and expiry, deductions, duplicates, unassigned
payments, month-end totals, rand parsing and rounding, replacement funds and the
export. CI runs them on every push. No one has yet seen the screens on a phone or
simulator, and the automation has only been tested with one FNB card.
