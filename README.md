# MacSplorer

A two-pane file manager for macOS, in the spirit of **Windows Explorer**: an
expandable folder tree on the left, a sortable **details** list (Name *with
extensions*, Date Modified, Type, Size) on the right, and a copyable full-path
address bar on top — the things that feel missing when you come to Finder from
Windows.

> **Status:** v0.1 — first public release.

## Features

Most of MacSplorer should be self-explanatory if you've used Windows Explorer,
and where macOS conventions apply, Finder. The essentials work the way you'd
expect:

- **Two panes** — a lazy, expandable folder tree and a details list, split and
  resizable.
- **Sortable columns** — Name, Date Modified, Type, Size. Folders sort apart
  from files; packages (`.app`, `.pvm`, …) show their aggregate size.
- **Right-click context menus** in both panes — Open, Open With ▸, Cut / Copy /
  Paste, Duplicate, Rename, Move to Trash, New Folder, Open in Terminal, Reveal
  in Finder, Copy Path.
- **File operations** — copy / cut / paste (with name-collision prompts),
  rename in place, duplicate, move to Trash, new folder. Live folder watching
  keeps every window current.
- **Quick Look** — press the spacebar to preview the selection, just like
  Finder.
- **Familiar shortcuts** — `⌘N` new window, `⌘⇧N` new folder, `⌘O` open,
  `⌘X/⌘C/⌘V` cut/copy/paste, `⌘D` duplicate, `⌘⌫` move to Trash, `⌘⇧.` show
  hidden files, `⌥⌘T` open the current folder in Terminal.
- **Finder interop** — drag and drop to/from Finder, Reveal in Finder, Copy
  Path.
- **Windows & tabs** — open multiple windows (`⌘N`), and use the standard macOS
  tab bar (**View ▸ Show Tab Bar**, **Merge All Windows**) to gather them into
  one tabbed window. *The tabs are fully functional today using the native macOS
  tab bar; a future version will give them a more browser- / Explorer-like look.*

The one part that goes beyond what Explorer or Finder offer — and is worth
learning — is the address bar, described next.

## The Filesystem Address Bar (FAB)

The full-path bar across the top is the **Filesystem Address Bar**. Beyond
showing and copying the current location, it's built for fast keyboard
navigation:

- **Type a path and press Enter.** A folder path navigates there; a file path
  **opens** the file (it doesn't rename it — Finder's address-style behavior).
  The left tree expands and selects to match.

- **Case-insensitive, and case-correcting.** You can type `~/desktop` and on
  Enter it both navigates and rewrites the field to the real on-disk casing
  (`~/Desktop`), component by component, while preserving friendly symlink names
  (e.g. `~/OneDrive`).

- **Append-and-keep-typing.** After you Enter into a folder, the FAB appends a
  trailing `/` and leaves the cursor at the end — so you can immediately type
  the next segment and keep descending without reaching for the mouse.

- **Type-ahead completion.** As you type a segment, the FAB matches it against
  the real directory contents (folders suffixed with `/` so you can keep
  traversing):
  - **Multiple matches** → a list appears. Arrow down to a choice; **Enter**
    accepts *and* opens it, **Tab** accepts it and leaves you typing.
  - **One match** → the remainder is inline-filled and shown selected, so you
    can see exactly what's matched. **Tab** accepts it (keep typing); **Enter**
    accepts and opens it.
  - **While deleting** (backspacing), the match list still updates so you keep
    your bearings — it just doesn't inline-fill, so it won't fight you.

- **Tab into the field** puts the cursor at the end (ready to extend the path)
  rather than selecting everything; clicking still places the cursor where you
  click.

- **Open in Terminal.** The button at the right of the FAB (or `⌥⌘T`) opens a
  Terminal window at the path currently in the field.

## Building

Needs only the Xcode **Command Line Tools** (Swift + the macOS SDK) — no full
Xcode required. It's a Swift Package, so it also opens directly in Xcode if you
have it.

```sh
swift build               # compile
bash scripts/build.sh     # compile + assemble (and sign) build/MacSplorer.app
open build/MacSplorer.app # run
```

## Architecture

- **`MacSplorerCore`** — pure model layer (filesystem items, directory loading,
  sorting, formatting). No UI; testable in isolation.
- **`MacSplorerApp`** — AppKit UI (programmatic, no Storyboards): the window,
  the `NSOutlineView` folder tree, the `NSTableView` details list, and the FAB
  and status bars.

## License

[MIT](LICENSE) © 2026 Mark Ryland
