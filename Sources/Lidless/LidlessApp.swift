import AppKit

/// Plain AppKit entry point. The SwiftUI App lifecycle routes URL events to scenes, and a menu bar
/// app has none, so lidless:// links failed with error -609. NSApplication delivers them to the delegate.
@main
@MainActor
enum LidlessMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        let urls = pendingURLs
        pendingURLs = []
        urls.forEach(receive)
    }

    /// lidless:// links, delivered by NSApplication. May arrive before launch finishes.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(receive)
    }

    /// Opening the app again (Finder, Spotlight, `open -a Lidless`) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    private func receive(_ url: URL) {
        guard let model, let statusItem else {
            pendingURLs.append(url)
            return
        }
        if url.host == "show" {
            statusItem.showWindow()
        } else {
            model.handle(url: url)
        }
    }
}
