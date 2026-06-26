# MacSplorer

A two-pane file manager for macOS, in the spirit of Windows Explorer: an
expandable folder tree on the left, a sortable **details** list (Name with
extensions, Date Modified, Type, Size) on the right, and a copyable full-path
address bar on top — the things that feel missing when you come to Finder from
Windows.

> **Status:** early work in progress (v0.1, browse-only). Not yet released.

## Building

Needs only the Xcode **Command Line Tools** (Swift + the macOS SDK) — no full
Xcode required. It's a Swift Package, so it also opens directly in Xcode if you
have it.

```sh
swift build               # compile
bash scripts/build.sh     # compile + assemble build/MacSplorer.app
open build/MacSplorer.app # run
```

## Architecture

- **`MacSplorerCore`** — pure model layer (filesystem items, directory loading,
  sorting, formatting). No UI; testable in isolation.
- **`MacSplorerApp`** — AppKit UI (programmatic, no Storyboards): the window,
  the `NSOutlineView` folder tree, the `NSTableView` details list, the address
  and status bars.

## Roadmap

- **v0.1** — browse-only: tree, details columns, address bar, open / reveal.
- **v0.2** — file operations: copy / cut / paste, rename, delete-to-Trash, new
  folder.
- **v0.3** — polish + a signed, notarized public release.

## License

[MIT](LICENSE) © 2026 Mark Ryland
