import AppKit

/// A named snapshot of where the app's windows sit — the absolute screen frame
/// of each open window, captured as a group.
struct WindowLayout: Codable {
    var name: String
    var frames: [CGRect]
}

/// Persists named window layouts plus the last window frame (for restore-on-
/// restart). Shared app-wide.
final class WindowLayoutStore {
    static let shared = WindowLayoutStore()

    private let defaults = UserDefaults.standard
    private let layoutsKey = "windowLayouts"
    private let lastFrameKey = "lastWindowFrame"

    // MARK: Named layouts

    func layouts() -> [WindowLayout] {
        guard let data = defaults.data(forKey: layoutsKey),
              let list = try? JSONDecoder().decode([WindowLayout].self, from: data) else { return [] }
        return list
    }

    func layout(named name: String) -> WindowLayout? {
        layouts().first { $0.name == name }
    }

    /// Save (or overwrite) the layout `name` with `frames`.
    func save(name: String, frames: [CGRect]) {
        var list = layouts().filter { $0.name != name }
        list.append(WindowLayout(name: name, frames: frames))
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        write(list)
    }

    func delete(name: String) {
        write(layouts().filter { $0.name != name })
    }

    private func write(_ list: [WindowLayout]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: layoutsKey)
    }

    // MARK: Restore-on-restart

    /// Frames of all windows at last quit, so the app reopens the same
    /// arrangement instead of the OS-default centered window.
    var lastSessionFrames: [CGRect] {
        get {
            guard let data = defaults.data(forKey: lastFrameKey),
                  let frames = try? JSONDecoder().decode([CGRect].self, from: data) else { return [] }
            return frames
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: lastFrameKey) }
    }
}
