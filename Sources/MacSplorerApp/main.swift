import AppKit

// Programmatic entry point (no @NSApplicationMain / no Storyboard). Keeping the
// bootstrap explicit makes the app buildable with only the Command Line Tools.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
