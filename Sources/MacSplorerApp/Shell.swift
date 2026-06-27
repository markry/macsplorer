import AppKit

enum Shell {
    /// Open a new Terminal window cd'd into `folder`.
    static func openInTerminal(_ folder: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", folder.path]
        try? process.run()
    }
}
