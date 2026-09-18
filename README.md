# MacSplorer

A two-pane file manager for macOS, in the spirit of **Windows Explorer**: an
expandable folder tree on the left, a sortable **details** list (Name *with
extensions*, Date Modified, Type, Size) on the right, and a copyable full-path
address bar on top — the things that feel missing when you come to Finder from
Windows.

> **Status:** v0.10.0.

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
Two parts go beyond what Explorer or Finder offer and are worth learning: the
address bar, described next, and **Amazon S3 support** further down — buckets
browsed, and written to, like folders.

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

## Amazon S3

MacSplorer browses S3 as if it were a disk. An AWS profile appears as a volume
under **Volumes**, its buckets are the folders inside, and object keys become the
folder tree below that — so the same list, tree, drag, copy/paste and Quick Look
you use locally work against a bucket.

Nothing is stored by MacSplorer: it reads the AWS `config` and `credentials`
files you point it at and signs in with the profile you pick. There is no
fallback to anyone else's credentials — a profile that can't sign in fails
rather than quietly using another identity.

**Connecting.** **File ▸ Connect to External Files ▸ Amazon S3…** opens the list
of folders MacSplorer scans for AWS files (`~/.aws` by default). Add another —
a cloud-synced folder holding separate work and personal credentials, say — with
**Add…**, or by dragging a folder onto the list. **Add Current Folder** takes the
folder the browser window is showing, which saves fighting Finder's open panel
over hidden dot-folders. Every profile with usable credentials shows up as a
volume; profiles with no way to sign in are left out instead of appearing broken.

**Browsing.** A folder in S3 is a shared key prefix, not a thing in its own
right, so the tree is derived from the keys themselves. Listing pages through
large prefixes as you go, and the status bar shows progress for anything slow.
Since S3 sends no change notifications, refresh is manual (`⌘R`).

**Opening and downloading.** Opening a file downloads it to a session cache and
hands it to the app it belongs to; Quick Look (Space) does the same. Drag objects
to the Finder or another folder, or copy/paste them out — both transfer the bytes.

**Uploading.** Drag or paste files and folders into a bucket or prefix and they
upload, keeping a folder's structure. Uploads stream from disk rather than being
read into memory, so size is limited by the bucket, not by RAM — with one
exception: a single file larger than **5 GB** needs multipart upload, which isn't
implemented yet, and is refused with a clear message rather than failing part-way.
Copying between two S3 locations works too (including across profiles and
accounts), staged through a temporary local file.

**Deleting.** S3 has no Trash, so **Move to Trash** (`⌘⌫`) asks what you mean:

- **Copy to Local Trash** — download everything first, into a dated folder in
  `~/.Trash`, then delete from the bucket. Recoverable afterwards.
- **Full Deletion** — remove it from the server immediately. Not undoable.

Before asking, MacSplorer takes a bounded look at what's there: one listing
request, so the dialog appears immediately, reporting either an exact count and
size ("23 objects · 1.2 MB") or "More than 1,000 objects" when there's more than
a page. It deliberately does *not* count a large prefix in full — that can take
minutes — and the page it just listed becomes the first batch it deletes.

Long deletes show progress in the status bar with a **Stop** button. Stopping
leaves what's already deleted deleted and the rest untouched; stopping during a
copy-to-Trash deletes nothing at all, since the copy must finish first. On a
versioned bucket this deletes the current version, as the AWS console's Delete
does.

**Buckets.** In a profile's volume, **New Folder** (`⌘N`) becomes **New Bucket**:
a name and a region. The region list is the set of regions *enabled for that
account*, read via `ec2:DescribeRegions` — which includes opt-in regions you've
turned on and excludes those you haven't. Profiles lacking that permission (it's
not part of S3 access) fall back to a built-in list of the always-on regions;
either way the field is editable, so you can type any region. Bucket names are
checked against S3's rules before the request goes out. Deleting a bucket empties
it first and then removes the bucket itself; the confirmation says so.

Inside a bucket, **New Folder** writes a zero-byte `name/` marker, the same
convention the AWS console uses — which is also how an empty folder can exist in
a store that has no folders.

**Sharing a link.** Right-click an object ▸ **Copy Download Link…** creates a
presigned URL: pick how long it lasts, whether the browser should display the
file or download it, and the content type it's served as. The type defaults to
what the file's extension implies rather than what's stored on the object, since
objects are routinely stored as `application/octet-stream` and a video then
silently refuses to play; **Stored type** keeps the object's own.

**What isn't there yet.** Renaming (S3 has no atomic rename — it would be a copy
plus a delete), multipart upload for files over 5 GB, and moving a folder between
two remote locations in one step.

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
- **`MacSplorerS3`** — the Amazon S3 backend, behind the same `FileSystemProvider`
  seam the local filesystem uses, so the UI treats a bucket and a disk alike.
  Remote work that can run long (listing, deleting) reports progress and can be
  stopped.

## License

[MIT](LICENSE) © 2026 Mark Ryland
