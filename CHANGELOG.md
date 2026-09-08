# Changelog

## 2026-09-07

- Initial build: standalone Tools-menu entry, single-page Currently
  Reading shelf with a pinned search-and-add row.
- Vendored a trimmed copy of `hardcoverapp.koplugin`'s GraphQL client
  (MIT-licensed, see `THIRD_PARTY_NOTICES.md`) instead of depending on it
  at runtime.
- Own config file named `hardcovershelf_config.lua`, to avoid a
  module-name collision with `hardcoverapp.koplugin`'s own
  `hardcover_config.lua`.
- Fixed `listByStatus` returning no results (invalid GraphQL variable
  usage).
- Reworked two separate menu entries into one page with a pinned search
  row.
- Added an edition picker (ebook format, English by default, both
  changeable) instead of auto-linking whichever edition Hardcover returned
  first.
- Added a star-rating prompt after marking a book Read.
- Added series display (title, author, series position/name). No "of N"
  total: Hardcover's release-date data has a real ambiguity between an
  imprecise real date and a placeholder future date, checked against 6
  real series, so a computed total risked being wrong some of the time.
- Built a custom scrollable list (`lib/book_list.lua`) to replace core
  `Menu`, which has no way to render a custom child widget per row.
- Series tag renders as a rounded-corner background pill, positioned
  inline right after the title/author text.
- Fixed ghosting between stacked overlay screens by forcing a full-screen
  refresh on show/close.
- Known temporary state: the search dialog pre-fills a test query, needs
  removing before this is finished.
- Added a pinned Refresh row on the shelf page, to re-fetch the Currently
  Reading list without leaving the plugin.
- Fixed the "Title: Read" status toast showing at the same time as the
  rating picker, blocking it for a couple seconds. Now shown after the
  rating picker closes instead of being shown, or dropped, alongside it.
- Fixed the rating picker's Save button being permanently disabled at the
  default 2.5 rating: `SpinWidget` only enables Save once the value
  differs from its starting point unless told otherwise, and there's never
  a pre-existing rating being edited here.
- Redesigned the shelf and search screens against a design handoff
  (mockup + CSS): custom header (title + icon buttons, two layouts for
  the shelf vs. search/back-button screens) replacing the pinned
  search/refresh/back rows; a subheader showing the book count; rows
  rebuilt with a cover placeholder, serif title/author, and a progress
  bar/meta line fed by Hardcover's own `progress_pages`/`started_at` where
  a book has a logged reading session.
- Fixed a font-fallback path (`ui/font.lua`'s raw-filename fallback) to
  pull in real serif faces (`NotoSerif-*.ttf`) for titles/authors, instead
  of the sans-only named faces every other widget in this codebase uses.
- Replaced the search popup-then-results-overlay flow with a single
  search page: a fake text field + language chip (both open a small popup
  on tap rather than being live-editable -- KOReader's `InputText` can be
  embedded standalone, but only by keeping one instance alive across an
  in-place refresh, which this plugin's close-and-rebuild screen model
  doesn't support), a result count line, and the results list itself.
  Language filtering is shared with the existing per-book edition-picker
  override instead of being a separate implementation.
- Fixed two `FrameContainer` layout bugs where a forced `width`/`height`
  went out of sync with what `getSize()` reports (it computes from
  content + padding + border, ignoring any forced size): the cover
  placeholder's initial letter rendering off-center, and the search
  field/language chip corrupting each other's position.
- Replaced the status picker's stock `ButtonDialog` with a custom modal
  (`lib/status_picker.lua`) matching the design handoff: a 2x2 grid of
  status tiles that only mark a selection (inverting to filled black with
  a checkmark) rather than committing immediately, a Done button that's
  disabled until one is chosen, and Read still auto-advancing straight to
  the rating picker. Dims the screen behind it via Blitbuffer's own
  `:darkenRect()` (real alpha blending against whatever's already
  painted, not a flat fill overwriting it).
- Auto-links the ebook edition with the most Hardcover readers for a
  newly-added book, instead of showing a picker screen to choose between
  near-duplicate editions by hand: `findEditions` already returns results
  ordered by `users_count desc_nulls_last` (confirmed live against the
  API), and filtering by format/language preserves that order, so the
  first entry left is the most-read match. The per-book language override
  this replaces is gone; the search page's own language chip is now the
  only override, applied before you tap a result.
- Added `HardcoverApi:createRead`, adapted from `hardcoverapp.koplugin`'s
  own `insert_user_book_read` mutation (one real bug fixed along the way:
  upstream checks the wrong response field, so its own version silently
  returns nothing). Marking a book Currently Reading now plants a reading
  session automatically if it doesn't already have one, instead of
  leaving the shelf's progress bar/meta line blank until a real update
  gets logged through Hardcover's own site or app.
- Fixed the progress bar/meta line not showing even when a reading
  session exists: Hardcover normalizes an explicit `progress_pages: 0` to
  `null` server-side (confirmed live), so requiring a non-null value
  before showing anything was too strict -- a null `progress_pages` is
  now treated as 0%, same as the site's own "add an update without
  changing anything" flow already produces.
