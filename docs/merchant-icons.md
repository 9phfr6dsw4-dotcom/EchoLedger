# Merchant icons

EchoLedger uses a small, offline artwork catalog. Logos appear beside merchants in
Transactions, the selected transaction's details, merchant and income reports,
expanded category rows, recurring charges, and report drill-downs. All three PDF
styles embed the same artwork in merchant, income-source, and recurring rows.

The catalog initially contains 48 brand marks. A resolved merchant name must match
one of the explicitly listed names. EchoLedger does not guess brands from parts
of names, search the App Store, send bank descriptions to another service, or
change transaction classification to obtain a logo. Fictional demo merchants use
neutral symbols; other merchants use their category symbol or initials. Transfers
use transfer arrows. Missing artwork immediately falls back to a symbol or initials.

Artwork is cached in memory and shipped in the SwiftPM core resource bundle, so
it also works offline and after installing an exported app ZIP. No ledger schema
or saved preferences change. Brand marks retain their proportions and colors on
a light tile that stays legible in both app appearances and on paper.

## Artwork provenance and additions

`Sources/EchoLedgerCore/Resources/MerchantIcons/catalog.json` records exact merchant
names, asset filenames, upstream SVG URLs, upstream brand sources, brand colors,
and source/output SHA-256 hashes. These marks come from **Simple Icons 13.21.0**;
its CC0 license is included alongside the catalog. Brand names and marks remain
the property of their respective owners and identify transaction merchants.

Each bundled PNG is a 192 × 192 rendering of the upstream SVG using its upstream
brand color. To add a brand, add its PNG and a catalog entry with explicit names;
do not introduce substring or fuzzy matching. Tests validate every resource,
decode its image, check catalog name uniqueness, and exercise matching boundaries.

## Validation

Run `swift test` on macOS 26 with Swift 6.2, then `bash Scripts/package-app.sh`.
The packaging script includes and checks the core resource bundle in both the
app and extracted ZIP. CI also launches that extracted app after hiding `.build`.

The PDF suite checks embedded image objects in every style, retained merchant
names and amounts, and pagination with long names and notes. To check visually,
open a demo workspace, inspect Transactions and Reports → Merchants, expand a
category, and export Signature, Everyday, and Precision PDFs. These checks can be
done without any personal ledger data or network connection.
