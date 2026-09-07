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
