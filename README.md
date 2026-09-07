# hardcovershelf.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin for browsing a [Hardcover.app](https://hardcover.app) "Currently Reading" shelf and changing a book's status, or searching Hardcover's catalog and adding a new book, all without opening a document first.

The motivating gap: [hardcoverapp.koplugin](https://github.com/billiam/hardcoverapp.koplugin)'s own status menu only ever acts on whatever book is currently open in the reader. That breaks down for manga read chapter-by-chapter through [Rakuyomi](https://github.com/tachibana-shin/rakuyomi), where there's no single "document" tied to a whole volume, so a finished volume can never be marked read from inside a book. This plugin exists to fill that one gap with a standalone shelf, reachable from anywhere, not tied to any document being open.

## Installation

Copy the whole `hardcovershelf.koplugin` folder into a KOReader `plugins/` directory:

```
koreader/plugins/hardcovershelf.koplugin/
```

Restart KOReader. "Hardcover Shelf" shows up under **Tools**.

## Setup

Open `hardcovershelf_config.lua` and paste in a Hardcover API token, replacing the placeholder value. This is a separate config file from `hardcoverapp.koplugin`'s own `hardcover_config.lua`, deliberately (see `lib/hardcover_api.lua`'s header comment for why sharing a filename between two plugins is actually risky here, not just redundant).

## Features

- **Currently Reading list**: opens directly from Tools with no submenu arrow, showing books pulled live from Hardcover.
- **Search and add a book**: a pinned row on the shelf page opens a search box, and results appear as an overlay on top of the shelf rather than replacing it.
- **Edition picker**: newly-added books go through an edition-selection step instead of letting Hardcover silently default to whichever edition it likes (the original bug report: a test add landed on an audiobook edition with no way to choose otherwise). Defaults to ebook format in English, both changeable inline, with a fallback to other formats or languages and an explicit on-screen notice when nothing narrower is available.
- **Status change**: the same four statuses (Want to Read, Currently Reading, Read, Did Not Finish) `hardcoverapp.koplugin` itself offers.
- **Rating prompt**: marking a book Read shows a star rating picker right after.
- **Context-aware presentation**: opens as a centered overlay on top of the page being read when inside a book, and as a true fullscreen page when opened from the file manager, matching how Rakuyomi's own library view presents itself there.
- **Series display**: a book that's part of a series shows its position and series name alongside the title and author.

## How it works

`lib/hardcover_api.lua` is a trimmed, adapted copy of `hardcoverapp.koplugin`'s own GraphQL client (MIT-licensed, see `THIRD_PARTY_NOTICES.md`), not a runtime dependency on that plugin being installed, since KOReader plugins can't cleanly `require()` each other's internals across plugin folders. Its config file is named `hardcovershelf_config.lua` rather than `hardcover_config.lua` for a specific reason: KOReader merges every installed plugin's root folder into one shared `package.path` after startup, so two plugins both naming a config module `hardcover_config` would collide in Lua's `require` cache, and one would silently load the other's token.

The shelf renders through a small custom list widget (`lib/book_list.lua`) rather than KOReader's core `Menu`, which has no way to render a styled child widget per row (its secondary-text field is hard-coerced into a plain `TextWidget`). The list is configured differently depending on where it's opened from: inside a book it opens as a centered popout sitting on top of the page being read; from the file manager it opens as a true edge-to-edge page instead.

Adding a book from search fetches every edition Hardcover has for it and filters to ebook format in English by default, both changeable from the same screen, falling back to other formats or languages with an explicit notice when nothing narrower exists yet. Hardcover's own `insert_user_book` mutation will otherwise silently pick an edition with no input at all.

A book that's part of a series shows its position and series name as a rounded-corner tag next to the title and author. It deliberately doesn't show a "book N of M" total the way Hardcover's own site does: release-date data in the underlying catalog has a real ambiguity between "exact release day unknown" and "placeholder for an unconfirmed future book" that no field distinguishes, so a computed total would be right most of the time and silently wrong the rest of the time.

## Known v1 limitations

- **No "of N" series total** (see How it works above for why).
- **Edition can't be changed for an already-linked shelf book.** Only newly-added books go through the edition picker; changing an existing link's edition would require confirming an assumption about the API's upsert behavior that hasn't been verified yet.
- **No offline queueing.** Every action needs a live connection at the moment it's taken.
- **Author display uses an empirically reverse-engineered field**, not a schema-documented one. Hardcover's contributor data is an opaque JSON blob the schema doesn't describe the shape of, so this mirrors a working pattern from a sibling plugin's code instead of a verified type definition.

## Structure

```
hardcovershelf.koplugin/
├── _meta.lua                        (plugin name and description)
├── main.lua                         (registers under Tools)
├── hardcovershelf_config.lua        (API token goes here, placeholder by default)
├── hardcovershelf_config.example.lua
├── THIRD_PARTY_NOTICES.md           (attribution for vendored code)
└── lib/
    ├── hardcover_api.lua            (GraphQL client)
    ├── table_util.lua               (small table helpers)
    ├── constants.lua                (status id constants)
    ├── book_list.lua                (custom scrollable list widget)
    └── shelf_ui.lua                 (every screen: shelf, search, edition
                                       picker, status picker, rating)
```
