<p align="center">
  <img src="docs/images/echoledger-icon.png" width="88" alt="EchoLedger app icon">
</p>

<h1 align="center">EchoLedger</h1>

<p align="center">Private budgeting for macOS: import bank CSVs, get merchants and categories right, and see clear reports, with Apple Intelligence on your Mac.</p>

<p align="center"><a href="https://github.com/9phfr6dsw4-dotcom/EchoLedger/releases/latest"><strong>Download the latest release</strong></a> · macOS 26+ · Apple Silicon</p>

<p align="center">
  <a href="https://github.com/9phfr6dsw4-dotcom/EchoLedger/releases/latest"><img src="https://img.shields.io/github/v/release/9phfr6dsw4-dotcom/EchoLedger?display_name=tag" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26 or later">
  <a href="https://github.com/9phfr6dsw4-dotcom/EchoLedger/actions/workflows/macos-ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/9phfr6dsw4-dotcom/EchoLedger/macos-ci.yml?branch=main&amp;label=macOS%20CI" alt="macOS CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

## Features

- **Import any number of bank and card CSVs at once.** Chase, Apple Card, Citi, Capital One, Wells Fargo, Comenity (Macy's and other store cards), Discover, Amex and Bank of America are recognized automatically. For any other bank, or when a bank changes its file, Apple Intelligence works out which column is which and EchoLedger proves it on every row before using it; you can always choose the columns yourself. Either way the layout is remembered.
- **See everything before it's saved.** Each file shows its account, new rows, rows already saved, pending charges being replaced, possible duplicates held back for you, and any rows it couldn't read, with the reason. Every line of every file is accounted for. A backup is made before each import, and any import can be undone.
- **Merchants and categories you can trust.** Your own rules come first, then merchants you've taught EchoLedger, then built-in rules for bank wording (card payments, interest, paychecks, ATM) and a list of 275 well-known merchants. Payment services are seen through: “PAYPAL *COINBASE” is Coinbase. Every transaction shows why it was filed the way it was, and the original bank text.
- **Review that takes seconds.** Transactions with identical bank text are grouped, so one decision covers all of them. Choose “Remember” and similar transactions are handled from then on.
- **Household-aware.** Add the people in your household; reports can show everyone or one person, and money moving between you counts as a transfer, not spending.
- **Reports.** Income vs spending, categories with merchant drill-down, comparisons with the previous period, 12-month trends, income sources, budgets, recurring charges and unusual charges. Export to PDF or CSV with the same numbers as the screen. Uncategorized and pending amounts are always shown, never hidden.
- **Apple Intelligence, on this Mac only.** After each import it files the transactions EchoLedger has never seen, following how you filed similar ones, and marks them “Filed by Apple Intelligence” so you can check them (or choose suggestions only, in Settings). It also tidies merchant names that look like bank text, explains unfamiliar charges, writes a short summary of each report, and answers questions like “How much did we spend on dining last quarter?” It only ever uses Apple's on-device model. Every answer is checked before it's used, everything it does is undoable, and when you correct one of its filings it stops filing that bank text.
- **Private by design.** No bank logins, accounts, subscriptions or servers. Your data stays in one file on your Mac.

## Install

1. Download `EchoLedger.zip` from the [latest release](https://github.com/9phfr6dsw4-dotcom/EchoLedger/releases/latest) and unzip it.
2. Drag **EchoLedger** into **Applications** (choose **Replace** when updating).
3. Open it. If macOS blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway**. (Builds are ad-hoc signed, so macOS treats every new build as a new app.)
4. For the Apple Intelligence features, turn on Apple Intelligence in **System Settings → Apple Intelligence & Siri**. Everything else works without it.

You need an Apple Silicon Mac with macOS 26 or later.

## Shortcuts

| Shortcut | What it does |
|---|---|
| **⌘O** | Import bank files. |
| **⌘1** to **⌘7** | Go to Import, Review, Transactions, Reports, Ask, Rules & Merchants or Settings. |
| **⌥⌘Z** | Undo the last change. |
| **⌘,** | Settings. |

## How it works

1. **Import.** Drop CSV files on the Import screen. EchoLedger reads each file's header to recognize the bank, suggests the account (or a new one), and compares every row with what's already saved:
   - exact repeats are skipped (two identical coffees on the same day stay two coffees),
   - a posted charge replaces its earlier pending version,
   - anything that only *looks* like a saved transaction is held back for you to decide.
2. **Match.** Each transaction gets a merchant (who) and a category (what for), decided separately, in this order: your rules → your household → merchants you've taught it → built-in rules → the built-in merchant list. If none of those knows it, Apple Intelligence files it (marked, counted in a note on your reports until you check it, and remembered for the same bank text next month). Otherwise a similar known merchant may *suggest* one, which you approve in Review.
3. **Report.** Only posted transactions count. Spending is purchases minus refunds; transfers and card payments are never income or spending; anything still needing review is listed separately. Every screen, chart, export and AI answer uses the same calculation.

Money is stored as exact cents, never as floating-point numbers. Dates from your bank files are kept exactly as written.

## Where your files are

| What | Where | Notes |
|---|---|---|
| **Your ledger** | `~/Library/Application Support/EchoLedger/EchoLedger.sqlite` | One file with everything: accounts, transactions, rules, merchants and settings. iCloud doesn't sync it. |
| **Backups** | `~/Library/Application Support/EchoLedger/Backups` | Made automatically each day and before every import (the newest 30 are kept), or with **Back Up Now**. Restore any of them from **Settings**. |
| **Your bank CSV files** | Wherever you keep them | EchoLedger only reads them. Optionally, it moves them into a folder you choose after importing, sorted by month. |

The original text of each imported row is kept so you can always see where a transaction came from. You can turn this off in **Settings**, which deletes the saved lines (descriptions stay). **Show in Finder** in Settings opens the folder.

## Privacy

Everything stays on your Mac. EchoLedger has no bank logins, no account, no subscription, no servers and no analytics. Apple Intelligence features use only Apple's on-device model, never a cloud service, and if Apple Intelligence is off or unavailable, importing, matching and reports work exactly the same. Turn on FileVault to encrypt your disk.

<details>
<summary>Build and test</summary>

You need macOS 26 and Xcode 26 (Swift 6.2).

```bash
swift test                       # run the tests
bash Scripts/package-app.sh      # build dist/EchoLedger.app and dist/EchoLedger.zip
bash Scripts/smoke-test.sh       # launch the packaged app from a clean folder
```

The project is a Swift package with no third-party dependencies:

- `Sources/EchoLedgerCore`: import, matching, reports, storage (SQLite), and the checks applied to Apple Intelligence results. Fully unit-tested with made-up bank files.
- `Sources/EchoLedgerApp`: the SwiftUI app and the Foundation Models integration.
- `Tests/EchoLedgerTests`: tests for the core.

</details>

## License

MIT. See [LICENSE](LICENSE).
