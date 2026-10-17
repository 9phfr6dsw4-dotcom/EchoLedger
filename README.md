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
- **Household spending.** Every account and card belongs to the household, and you choose who uses it (one person, several people, or no one in particular). Select everyone, one person, or multiple people in Reports and Transactions, and count either the spending assigned to them or everything on the cards they use. Correct individual transactions or a batch without changing the account. Cardholder details are used only when the bank export provides them. Transfers and card payments remain separate from spending.
- **Warm Ledger design.** A cream-and-forest workspace, clear financial typography, a new echo icon, organized settings, and light, dark, or system appearance.
- **Offline merchant icons.** Bundled logos for common brands, with category symbols or initials for other merchants. The same icons appear in transaction details, merchant reports, and all three exported PDF styles. No bank text is sent to an icon service. [Artwork and matching details](docs/merchant-icons.md).
- **Personal allowances.** Optionally set a monthly spending allowance for each person. Their report shows the allowance for complete calendar months and how their spending contributes to the household total.
- **Demo workspace.** Open a separate workspace with fictional data from File → Open Demo Workspace or Settings → General. It uses a temporary database and never opens your personal ledger.
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
2. **Match.** Each transaction gets a merchant (who) and a category (what for), decided separately, in this order: your rules → your household → merchants you've taught it → built-in rules → the built-in merchant list. If none of those knows it, Apple Intelligence files it (marked, counted in a note on your reports until you check it, and remembered for the same bank text next month; Zelle is the exception, because the bank text never says why the money moved, so Review always asks). Otherwise a similar known merchant may *suggest* one, which you approve in Review.
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

## Household assignments

In Settings → Household & Accounts, add people and choose who uses each account or card. A card can have several users, or none for a plain household card. Individual cards appear beneath an account when an import supplies cardholder or card-number details; unknown layouts can map those optional columns. New imports use the saved default. Choose Apply to Past Transactions to update earlier imports while preserving individual corrections; Undo reverses that action. Legacy shared accounts stay shared.

Reports and Transactions let you choose the whole household, selected people, shared spending, or unassigned transactions, and switch between two ways of counting for the people you pick: **Spending assigned to them** (follows each purchase, including single purchases you reassigned) or **Everything on their cards** (every purchase on a card they use; a card several of them use is counted once). Person-only reports exclude shared spending unless selected. Joint expenses count once in the whole-household total. Exports use the same selection and figures.

### PDF report styles

In Reports, choose **Export → Report as PDF…**, then select **Signature**, **Everyday**, or **Precision**. The last style is remembered. Every style exports the same selected people/cards, figures, income sources, merchant details, and report notes. Long reports continue onto additional letter-size pages with repeated scope and page numbers.

### Zelle

The bank text for a Zelle never says why the money moved, so EchoLedger doesn't guess: Apple Intelligence leaves Zelle alone, and **Review** asks. Money going out can be spending (with a category), a gift, or back-and-forth with someone. Money coming in can be income, something you sold, a gift received, someone paying you back (which lowers the category, like a refund), or back-and-forth. Zelle with a household member (see Household names in Settings) stays a transfer, not counted as income or spending.

- **Paying each other** is one spending category for people you pay back and forth. Money out adds to it and money in lowers it, so each month shows a net amount, which can be negative. It is never income.
- **Gifts received** is shown as its own line in Reports. It is counted in net cash flow but kept separate from income.
- Reports has a **Zelle** card that lists everyone you Zelled with (received, sent, net, and how each is counted), and Transactions has a **Zelle** filter. On a person's report, **Money moved within the household** shows what was sent to or received from the others in the household. Those lines change nothing in the totals.
