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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
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
        if let model { model.handle(url: url) } else { pendingURL = url }
    }
}
