# zanzan (攒攒)

[简体中文](README.md) · **English**

An iOS expense tracker written in SwiftUI and SwiftData. It's still in development and not on the App Store.

I built it because my own finances are messy: several credit cards sharing one limit, expenses I pay up front and get reimbursed for later, installments, foreign currency. Most bookkeeping apps either can't record that level of detail or put every feature on the home screen. The idea here is that adding an entry should take a few seconds, and the complicated parts only show up when you need them.

## What works today

- Multiple ledgers and accounts, two-level categories, expense / income / transfer, tags
- Monthly and per-category budgets, with per-entry exclusions
- Credit card statements and shared credit limits across cards
- Reimbursements and refunds, including partial and combined payouts
- Installments and loans (equal installments, equal principal, interest-only and more)
- Recurring entries such as rent and salary
- Multiple currencies and cross-currency transfers
- Balance adjustments, also used for investment valuations
- CSV import/export with duplicate detection and batch undo, receipt photos, full backup and restore
- Recently Deleted for ledgers, accounts and entries
- Chinese and English UI, switchable in the app

Not done yet: iCloud sync (the data model is designed for CloudKit, a few checks remain before turning it on) and a live exchange-rate source. The roadmap and database design docs in `docs/` are in Chinese.

## Tech stack

| | |
| --- | --- |
| Platform | iOS 26+ |
| UI | SwiftUI, native controls with Liquid Glass |
| Storage | SwiftData (15 tables), CloudKit private database planned |
| Language | Swift 6 |

## Running locally

Open `zanzan.xcodeproj` in Xcode and run the `zanzan` scheme.

Commit messages follow gitmoji and are checked by husky + commitlint (`<emoji> <type>(<scope>): <subject>`, full table in `commitlint.config.js`). Run `pnpm install` once after cloning to set up the hook.

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free for personal and non-commercial use; contact me for commercial use.
