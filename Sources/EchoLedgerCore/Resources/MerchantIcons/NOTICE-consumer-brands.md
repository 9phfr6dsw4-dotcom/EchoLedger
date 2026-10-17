# Consumer brand artwork

The `consumer-*.png` marks are adapted from the public **Open Food Facts Brand
Images** repository, pinned to revision
`9890268558563ee11cdfd89d23f99499234a40d3`:
https://github.com/openfoodfacts/brand-images/tree/9890268558563ee11cdfd89d23f99499234a40d3

`catalog.json` and `Scripts/merchant-icon-supplement.json` record the exact source
URL and source SHA-256 for each selected image. The catalog also records the
SHA-256 of the resized PNG. These marks are separate from the CC0 Simple Icons
collection; that license does not apply to this supplement. The source repository
does not declare a blanket artwork license. Copyright and trademark rights remain
with the respective owners. EchoLedger uses the marks solely to identify merchants;
no affiliation or endorsement is implied.

Sources are downloaded only by the development generator. The released app ships
the rendered artwork and performs all matching locally, including PDF exports.

## Additional requested service brands

- **Xfinity:** selfh.st Icons contributors, `selfhst/icons`, revision
  `1d65d45a42e6323b54b8096967b1ea4b65321f97`, `svg/xfinity.svg`.
  Source: https://github.com/selfhst/icons/tree/1d65d45a42e6323b54b8096967b1ea4b65321f97
  Collection license: CC BY 4.0, included in `LICENSE-selfhst.txt`.
- **Mister Car Wash:** `johnpantini/ppp` stock-icon collection, revision
  `7efa5d6a2cf84c3b2786a9c6223159db7e94e1b3`, `static/instruments/stocks/us/MCW.svg`.
  Source: https://github.com/johnpantini/ppp/tree/7efa5d6a2cf84c3b2786a9c6223159db7e94e1b3
  The source SVG credits TradingView. The repository's MIT notice is included in
  `LICENSE-ppp.txt`; merchant trademark rights remain with Mister Car Wash.

Adaptations: rasterized to PNG, empty margins trimmed, proportionally resized and
centered on a transparent 192 × 192 canvas. No brand affiliation is implied.

## Verified Wikimedia Commons originals

The following files are also available through the pinned public mirror above.
The generator verifies that the source bytes have the exact SHA-1 reported by
Commons, in addition to each source's SHA-256. Their original Commons revision,
author, and rights label are retained in both manifests:

- **Meijer:** Meijer, Inc., `File:Meijer_logo.svg`, Commons revision `1179161284`,
  SHA-1 `8834483635b3b0248d853a9e8ac005dd17226e4e`.
  https://commons.wikimedia.org/w/index.php?title=File:Meijer_logo.svg&oldid=1179161284
- **Hy-Vee:** unknown author as listed by Commons, `File:Hy-Vee_logo.svg`,
  Commons revision `1114707289`, SHA-1 `1e796318ff929a54eb860274f55daa903dcb9b5f`.
  https://commons.wikimedia.org/w/index.php?title=File:Hy-Vee_logo.svg&oldid=1114707289

Commons labels these two originals `PD-textlogo`. Their trademark notices still
apply. The PNG adaptations use the same rasterization and resizing described above.
