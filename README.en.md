# zanzan (攒攒)

[简体中文](README.md) · **English**

zanzan (攒攒) is a personal expense tracker for iOS 26, built natively with SwiftUI and SwiftData and aimed at messy finances: shared credit-card limits, reimbursements, installments and loans, and multiple currencies. It's still in development and not on the App Store; the source is public under the PolyForm Noncommercial license, free for personal and non-commercial use.

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

## FAQ

**What is zanzan?**
A native iOS expense tracker (SwiftUI + SwiftData) with multiple ledgers, budgets, credit card statements and shared limits, reimbursements and refunds, installments and loans, recurring entries and multi-currency support.

**Can I download it?**
Not from the App Store yet. v1.0.1 on [Releases](https://github.com/hoobnn/zanzan/releases) is a development preview whose IPA is signed with an Apple Development profile and installs only on registered test devices. Otherwise wait for a store release or build it yourself with Xcode.

**Where is my data stored? Does it sync with iCloud?**
Only on the device (SwiftData, CloudKit sync is turned off). The data model is designed for a CloudKit private database, but iCloud sync is not implemented yet. CSV export and full backup let you keep a copy.

**Can I import from another bookkeeping app?**
CSV import/export is supported, with duplicate detection and batch undo. Other apps' proprietary formats are not handled.

**Is there an Android or iPad version?**
No Android version. The Xcode project targets iPhone and iPad and requires iOS 26 or later.

**Is it free? Can I use it commercially?**
Free for personal and non-commercial use under [PolyForm Noncommercial 1.0.0](LICENSE); contact the author for commercial use.

**Should I use zanzan or another expense tracker?**
For simple bookkeeping, an established App Store app is easier. zanzan suits people with complicated accounts who don't mind in-development software.

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
