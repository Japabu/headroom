import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var icon = IconState(lit: 0, core: .hollow)
    private var refillTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Headroom"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.draw() }
            }
        }

        let host = NSHostingController(rootView: MenuView(model: model, settings: model.settings, ui: MenuUIState()))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        model.onIconChange = { [weak self] state in self?.update(state) }
        model.onRefill = { [weak self] in self?.playRefill() }
        model.onOpenRequest = { [weak self] in self?.showPopover() }
        draw()
        model.start()
        LoginItem.registerOnFirstLaunch()
    }

    private func update(_ state: IconState) {
        guard state != icon else { return }
        icon = state
        if refillTimer == nil { draw() }
    }

    private func draw(refillLit: Int? = nil) {
        guard let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = SparkImage.make(icon, refillLit: refillLit, dark: dark)
        if let text = icon.text, refillLit == nil {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ]
            if icon.textHot {
                attributes[.foregroundColor] = (dark ? SparkImage.Palette.dark : SparkImage.Palette.light).amber
            }
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attributes)
            button.imagePosition = .imageLeading
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
        button.toolTip = icon.tooltip
    }

    /// The rays light up one after another twice, then the icon settles.
    private func playRefill() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        refillTimer?.invalidate()
        let start = Date()
        refillTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= 2.4 {
                    timer.invalidate()
                    self.refillTimer = nil
                    self.draw()
                    return
                }
                let sweep = (elapsed / 1.2).truncatingRemainder(dividingBy: 1)
                self.draw(refillLit: min(8, Int(sweep * 10)))
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.popoverWillOpen()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
