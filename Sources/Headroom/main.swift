import AppKit
import SwiftUI

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--render-icon" {
    IconExport.writeIconset(to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}

if arguments.count >= 2, arguments[1] == "--dump" {
    Diagnostics.dump()
    exit(0)
}

if arguments.count >= 3, arguments[1] == "--snapshot" {
    MainActor.assumeIsolated { Diagnostics.snapshot(to: URL(fileURLWithPath: arguments[2])) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

/// Command-line checks. Neither one renews logins or posts notifications.
enum Diagnostics {
    /// `Headroom --dump`: what Headroom finds and reads, without tokens.
    static func dump() {
        let accounts = Discovery.accounts(extraDirs: UserDefaults.standard.stringArray(forKey: "extraConfigDirs") ?? [])
        print("Found \(accounts.count) Claude Code login(s)")
        let now = Date()
        for a in accounts {
            let activity = Discovery.activity(a.configDir)
            print("\n\(a.item.service)")
            print("  folder:  \(a.configDir?.path ?? "unknown")")
            print("  email:   \(Discovery.email(a.globalConfig) ?? "unknown")")
            print("  running: \(activity.running) Claude Code session(s), last activity \(activity.last.map { Fmt.when($0, now: now) } ?? "none")")
            let done = DispatchSemaphore(value: 0)
            var outcome = Fetcher.Outcome()
            Task.detached {
                outcome = await Fetcher.run(item: a.item, claudeRunning: activity.running > 0, renewAllowed: false, wantEmail: false)
                done.signal()
            }
            done.wait()
            print("  plan:    \(outcome.plan ?? "unknown")")
            if let issue = outcome.issue { print("  issue:   \(issue.message)") }
            for w in outcome.usage?.all ?? [] {
                var line = "  \(w.label): \(Int(w.percent.rounded()))% used"
                if let r = w.resetsAt { line += ", resets \(Fmt.when(r, now: now)) (in \(Fmt.duration(r.timeIntervalSince(now))))" }
                if let p = w.projected(now) { line += ", on pace for \(Int(p.rounded()))%" }
                if let out = w.runsOut(now) { line += ", runs out ~\(Fmt.when(out, now: now))" }
                if w.isSessionLength ? w.isHot(now) : w.isLow { line += "  [hot]" }
                print(line)
            }
        }
    }

    /// `Headroom --snapshot <dir>`: renders the menu with live data plus every icon state to PNGs.
    @MainActor static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        model.start(quiet: true)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if model.discovered, !model.isRefreshing, model.accounts.allSatisfy({ $0.usage != nil || $0.issue != nil }) { break }
        }
        for dark in [false, true] {
            let view = MenuView(model: model, settings: model.settings, ui: MenuUIState())
                .background(dark ? Color(white: 0.17) : Color(white: 0.97))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage { writePNG(image, to: dir.appendingPathComponent(dark ? "menu-dark.png" : "menu-light.png")) }
        }

        let states: [IconState] = [
            IconState(lit: 8), IconState(lit: 5), IconState(lit: 2, hot: true, text: "14%", textHot: true),
            IconState(lit: 0, core: .hollow, text: "2:19"), IconState(lit: 7, core: .amber),
            IconState(lit: 0, core: .red, text: "Tue"), IconState(lit: 0, core: .hollow, badge: true, text: "2:19"),
        ]
        let cell = NSSize(width: 64, height: 30)
        let strip = NSImage(size: NSSize(width: cell.width * CGFloat(states.count), height: cell.height * 2), flipped: true) { _ in
            for (row, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.91, alpha: 1)).setFill()
                NSRect(x: 0, y: CGFloat(row) * cell.height, width: cell.width * CGFloat(states.count), height: cell.height).fill()
                for (i, st) in states.enumerated() {
                    let origin = NSPoint(x: CGFloat(i) * cell.width + 6, y: CGFloat(row) * cell.height + 6)
                    SparkImage.make(st, dark: dark).draw(in: NSRect(origin: origin, size: NSSize(width: 18, height: 18)))
                    if let text = st.text {
                        let palette = dark ? SparkImage.Palette.dark : SparkImage.Palette.light
                        (" " + text).draw(at: NSPoint(x: origin.x + 18, y: origin.y + 1), withAttributes: [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                            .foregroundColor: st.textHot ? palette.amber : palette.ink,
                        ])
                    }
                }
            }
            return true
        }
        writePNG(strip, to: dir.appendingPathComponent("icon-states.png"), scale: 3)
        print("Wrote snapshots to \(dir.path)")
    }

    private static func writePNG(_ image: NSImage, to url: URL, scale: CGFloat = 1) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
