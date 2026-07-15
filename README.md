# MacSplorer

A two-pane file manager for macOS, in the spirit of **Windows Explorer**: an
expandable folder tree on the left, a sortable **details** list (Name *with
extensions*, Date Modified, Type, Size) on the right, and a copyable full-path
address bar on top — the things that feel missing when you come to Finder from
Windows.

> **Status:** v0.8.2.

## Download

Grab the latest build from the
[**Releases**](https://github.com/markry/macsplorer/releases/latest) page:
download `MacSplorer-X.Y.Z.zip`, unzip it, and drag **MacSplorer.app** into
`/Applications`. It's Developer-ID signed and notarized, so it opens without
Gatekeeper warnings — no Xcode or build step required.

To update later, download the new zip and either drag-replace the app, or run
the `upgrade.sh` attached to each release (it quits the app, verifies the new
build's signature + notarization, swaps it in, and relaunches — preferences are
preserved):

```sh
bash upgrade.sh   # uses the newest MacSplorer-*.zip in ~/Downloads
```

## Features

Most of MacSplorer should be self-explanatory if you've used Windows Explorer,
and where macOS conventions apply, Finder. The essentials work the way you'd
expect:

- **Two panes** — a lazy, expandable folder tree and a details list, split and
  resizable. The tree's roots are **Home** and **Volumes** (mounted disks);
  **View ▸ Show Startup Disk** adds the `/` root when you want it (off by default).
  Right-click a mounted volume to **Eject** it; the tree updates live as disks
  mount and unmount.
- **List & icon views** — the right pane shows either a details **list** or a
  thumbnail **icon grid** (content previews for images, PDFs, and video; file-
  type icons otherwise). Switch with the three-icon control at the right of the
  status bar — List / Small icons / Large icons — or **View ▸ as List** (`⌘1`),
  **as Small Icons** (`⌘2`), **as Large Icons** (`⌘3`). The view choice is
  **per-window**; other view settings are shared across windows.
- **Sortable, configurable columns** — Name, Date Modified, Type, Size by
  default; turn on Date Created, Date Added, and Date Last Opened via **View ▸
  Columns** or by right-clicking the column header. Drag to reorder and resize
  (Name stays first); **double-click a column's right edge** to size it to fit
  its content. Widths and order persist. Folders sort apart from files; packages
  (`.app`, `.pvm`, …) show their aggregate size.
- **"Up" row** — optionally (**View ▸ Show Up Item (..)**) a `..` row pins to the
  top of the list/grid; open it (or select it and press Return) to go to the
  parent folder. Off by default.
- **Favorites** — a pinned, resizable list at the top of the left pane for
  folders you jump to often. Right-click any folder to add/remove, or drag a
  folder onto it; drag within the list to reorder. Clicking a favorite jumps
  there and reveals it in the tree.
- **Right-click context menus** — the same folder menu across the list, icon
  grid, folder tree, and Favorites: Open, Open With ▸ (including **Set Default for
  All ".ext" Files**, the equivalent of Finder's Get Info ▸ Change All), Cut /
  Copy / Paste, Duplicate, Rename, Move to Trash, **New ▸**, Open in Terminal,
  Reveal in Finder, Copy Path, Add/Remove Favorites, and **Eject** for mounted
  volumes.
- **New ▸ submenu** — create a new Folder, or an empty document (Text, Markdown,
  Rich Text, CSV, Word, PowerPoint) ready to name, or an **Internet Shortcut**
  (`.url`) from the URL on your clipboard — written in the cross-platform format
  so it opens on macOS and in a Windows VM alike. The same set is available from
  **File ▸ New ▸**, and two have keyboard shortcuts (while MacSplorer is focused):
  **⌃⇧S** for an Internet Shortcut from the clipboard, **⌃⇧W** for a Word document.
- **File operations** — copy / cut / paste (with name-collision prompts),
  rename in place, duplicate, move to Trash (`⌫` or `⌘⌫`), new folder. Live
  folder watching keeps every window current. A failed transfer (out of space,
  permissions, …) reports the reason rather than failing silently.
- **Drag to move, ⌥-drag to copy** — and, Windows-Explorer-style, **right-button
  drag** drops a **Copy Here / Move Here** menu on release, defaulting to the
  opposite of the left-drag default (copy within a volume, move across volumes).
- **Quick Look** — press the spacebar to preview the selection, just like
  Finder.
- **Get Info** — **⌘I** or right-click ▸ **Get Info** opens a panel for the
  selected item: name, kind, location, and dates. For a **volume** it shows
  capacity / used / available with a bar; for a **folder**, the immediate item
  count plus a **Calculate** button for the full recursive total size; for a
  **file**, its size.
- **Folder sizes** — **Calculate Folder Sizes…** (in the **File** menu and the
  folder right-click menu) runs a parallel, low-priority background walk,
  totalling **size-on-disk**, and opens a results window: an indented outline of
  folders, biggest first, with size and % of total. Double-click a row to jump
  there. From a context menu it scans the folder you clicked; from the File menu,
  the current folder. Live progress (with a Stop button) shows in the status bar.
  Cloud (File Provider) mounts are skipped by default (**View ▸ Skip Cloud
  Storage When Scanning**), and because it counts on-disk bytes, online-only
  cloud files register as ~0.
- **Familiar shortcuts** — `⌘N` new window, `⌘⇧N` new folder, `⌘O` open,
  `⌘X/⌘C/⌘V` cut/copy/paste, `⌘D` duplicate, `⌘⌫` move to Trash, `⌘⇧.` show
  hidden files, `⌥⌘T` open the current folder in Terminal, `⌃⇧S` new Internet
  Shortcut from the clipboard, `⌃⇧W` new Word document.
- **Finder interop** — drag and drop to/from Finder, Reveal in Finder, Copy
  Path. Files dragged in from apps that hand off **promised files** (Outlook,
  Mail, Photos, Messages, …) are written into the target folder, just like Finder.
- **In-window menu bar** — optionally (**View ▸ Show Menu Bar**) the app's menus
  (File / Edit / View / Window) sit right under the tab strip, with hover to
  switch between them — so they're at the top of the *window*, not off in the
  corner of the screen.
- **Windows & tabs** — open multiple windows (`⌘N`) and browser-style tabs
  within a window: `⌘T` for a new tab, `⌘W` to close one, or the **+** button on
  the tab strip. Click a tab to switch; hover to reveal its close (✕). The strip
  hides itself when only one tab is open. Optionally (**View ▸ Raise All Windows
  Together**) have all windows come forward as a group when you switch to the app.
- **Window layouts** — save the current arrangement of *all* open windows as a
  named layout (**View ▸ Save Window Layout…**) and switch back to it any time
  (**View ▸ Apply Window Layout ▸**) — windows that don't fit the saved layout
  are closed, missing ones reopened. Absolute screen positions are saved as-is,
  so make a layout per monitor setup and pick it by name. The app also reopens
  the *last* arrangement on relaunch, instead of a single OS-centered window.
- **Tab between panes** — `Tab` cycles focus through the address bar → right pane
  → folder tree → Favorites (and `⇧Tab` reverses), landing on a usable selection
  each time.

The one part that goes beyond what Explorer or Finder offer — and is worth
learning — is the address bar, described next.

## The Filesystem Address Bar (FAB)

The full-path bar across the top is the **Filesystem Address Bar**. Beyond
showing and copying the current location, it's built for fast keyboard
navigation:

- **Breadcrumb ⇄ editable**, Windows-Explorer-style. When unfocused it shows the
  path as **clickable folder buttons** (`›`-separated, home as a house icon) —
  click any ancestor to jump straight there. Click the bar's empty area to turn
  it back into the **editable full path** (a trailing `/` and the cursor ready
  for the next segment), with everything below available.
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
  - **One match** → the remainder is inline-filled and shown selected, so you
    can see exactly what's matched.
  - **Multiple matches** → a list appears; arrow down to a choice.
  - **Tab and Enter both accept *and* descend** into the completed folder (or
    open the completed file). Because the app navigates instantly, descending
    reveals the folder's contents in the details pane — so you can see what to
    type for the *next* level. Tab and Enter are interchangeable here.
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
