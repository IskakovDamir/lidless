import AppKit
import SwiftUI

@main
struct LidlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Menu bar only. LSUIElement in Info.plist keeps the app out of the Dock.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        // Registered after SwiftUI finished its own setup so this handler is the one that wins.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        if let url = pendingURL {
            model.handle(url: url)
            pendingURL = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    private var pendingURL: URL?

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        receive(url)
    }

    /// Used for URLs that arrive before the handler above is installed (cold launch by URL).
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(receive)
    }

    private func receive(_ url: URL) {
        if let model { model.handle(url: url) } else { pendingURL = url }
    }
}
