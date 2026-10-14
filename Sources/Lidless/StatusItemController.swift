import AppKit
import Combine
import LidlessCore
import SwiftUI

/// Owns the menu bar item and its popover.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    private let popover: NSPopover
    private var subscription: AnyCancellable?
    private let idleIcon: NSImage
    private let activeIcon: NSImage
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        idleIcon = StatusIcon.make(active: false)
        activeIcon = StatusIcon.make(active: true)
        super.init()

        let host = NSHostingController(rootView: PopoverView().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.image = idleIcon
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        subscription = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
        updateButton()
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        model.popoverWillShow()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The same panel in a normal window. Used when the menu bar icon is hidden,
    /// for example behind the notch, and the app is opened again from Finder or Spotlight.
    func showWindow() {
        model.popoverWillShow()
        if window == nil {
            let host = NSHostingController(rootView: PopoverView().environmentObject(model))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Lidless"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let active = model.isActive
        let icon = active ? activeIcon : idleIcon
        if button.image !== icon { button.image = icon }

        var title = ""
        if active, model.showTimeInMenuBar {
            title = model.remaining.map { " " + DurationFormat.compact($0) } ?? " \u{221E}"
        }
        if button.title != title { button.title = title }

        button.toolTip = active ? "Lidless: keeping your Mac awake" : "Lidless: idle"
        button.setAccessibilityLabel(active ? "Lidless, session running" : "Lidless, idle")
    }
}

/// An eye: open with a green dot while a session runs, crossed out when idle.
/// Drawn on demand so the symbol follows the menu bar's light or dark appearance.
@MainActor
enum StatusIcon {
    static func make(active: Bool) -> NSImage {
        let symbolName = active ? "eye" : "eye.slash"
        let width: CGFloat = active ? 25 : 19
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor]))
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return false }
            let size = symbol.size
            symbol.draw(in: NSRect(x: (19 - size.width) / 2, y: (16 - size.height) / 2,
                                   width: size.width, height: size.height))
            if active {
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: 20, y: 2.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.cacheMode = .never
        image.isTemplate = false
        image.accessibilityDescription = active ? "Lidless active" : "Lidless idle"
        return image
    }
}
