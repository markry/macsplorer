import AppKit

/// The catalogue of columns the details pane can show. Each entry is a direct,
/// cheap filesystem property (no background computation) — title, default/min
/// width, and the canonical left-to-right position. Which columns are actually
/// visible (and in what order) lives in `Preferences.detailsColumns`; rendering
/// and sorting per column id live in `DetailsTableController`.
struct DetailsColumnSpec {
    let id: String
    let title: String
    let defaultWidth: CGFloat
    let minWidth: CGFloat

    /// Canonical order = the order columns appear in the picker and the natural
    /// slot a re-enabled column drops back into.
    static let all: [DetailsColumnSpec] = [
        .init(id: "name", title: "Name", defaultWidth: 300, minWidth: 120),
        .init(id: "dateModified", title: "Date Modified", defaultWidth: 170, minWidth: 100),
        .init(id: "dateCreated", title: "Date Created", defaultWidth: 170, minWidth: 100),
        .init(id: "dateAdded", title: "Date Added", defaultWidth: 170, minWidth: 100),
        .init(id: "dateLastOpened", title: "Date Last Opened", defaultWidth: 170, minWidth: 100),
        .init(id: "type", title: "Type", defaultWidth: 130, minWidth: 80),
        .init(id: "size", title: "Size", defaultWidth: 90, minWidth: 60),
    ]

    static func spec(id: String) -> DetailsColumnSpec? { all.first { $0.id == id } }

    /// Columns the user can toggle on/off (everything but the always-present Name).
    static var toggleable: [DetailsColumnSpec] { all.filter { $0.id != "name" } }

    /// Insert `id` into `visible` at its natural position per the canonical order,
    /// so a re-enabled column lands where you'd expect rather than at the end.
    static func insertInOrder(_ id: String, into visible: [String]) -> [String] {
        let rank = { (cid: String) in all.firstIndex { $0.id == cid } ?? all.count }
        let target = rank(id)
        var result = visible
        let at = result.firstIndex { rank($0) > target } ?? result.count
        result.insert(id, at: at)
        return result
    }
}
