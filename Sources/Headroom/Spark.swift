import AppKit
import SwiftUI

/// Everything the menu bar spark shows. Rays = 5-hour session (8 rays, 12.5% each), core = week.
struct IconState: Equatable {
    enum Core: Equatable { case solid, hollow, amber, red }

    var lit = 8
    var hot = false
    var core: Core = .solid
    var badge = false
    var text: String?
    var textHot = false
    var tooltip = "Headroom"

    static func make(for account: AccountState?, others: [AccountState], now: Date, mode: TextMode,
                     discovered: Bool = true) -> IconState {
        var st = IconState()
        guard discovered else {
            st.lit = 0; st.core = .hollow
            st.tooltip = "Headroom: looking for Claude logins"
            return st
        }
        guard let a = account else {
            st.lit = 0; st.core = .hollow
            st.text = mode == .never ? nil : "?"
            st.tooltip = "Headroom: no Claude Code login found. Run claude and /login."
            return st
        }
        guard let raw = a.usage else {
            st.lit = 0; st.core = .hollow
            st.text = mode == .never || a.issue == nil ? nil : "?"
            st.tooltip = "Headroom: " + (a.issue?.message ?? "reading usage…")
            return st
        }

        let u = raw.at(now)
        let session = u.session, week = u.week
        let weekOut = week?.isLimited ?? false
        let limited = session?.isLimited ?? false
        let hot = !weekOut && !limited && (session?.isHot(now) ?? false)
        let left = session?.left ?? week?.left ?? 100

        st.hot = hot
        if weekOut || limited {
            st.lit = 0
            st.core = .hollow
        } else {
            st.lit = max(0, min(8, Int((left / 12.5).rounded(.up))))
        }
        if weekOut { st.core = .red } else if week?.isLow == true { st.core = .amber }

        if mode != .never {
            if weekOut, let r = week?.resetsAt {
                st.text = Fmt.short(until: r, now: now)
            } else if limited {
                st.text = session?.resetsAt.map { Fmt.countdown($0.timeIntervalSince(now)) }
            } else if hot || mode == .always {
                st.text = "\(Int(left.rounded()))%"
                st.textHot = hot
            }
        }

        if hot || limited || weekOut {
            st.badge = others.contains { o in
                guard o.id != a.id, let ou = o.usage?.at(now), ou.week?.isLimited != true else { return false }
                return (ou.session?.left ?? 100) >= 50
            }
        }

        var parts: [String] = []
        if let s = session {
            parts.append("session \(Int(s.percent.rounded()))% used" + (s.resetsAt.map { ", resets \(Fmt.when($0, now: now))" } ?? ""))
        }
        if let w = week { parts.append("week \(Int(w.percent.rounded()))% used") }
        st.tooltip = "\(a.label): " + parts.joined(separator: " · ")
        return st
    }
}

enum SparkImage {
    struct Palette {
        let ink, amber, red, green: NSColor
        static let light = Palette(ink: .black, amber: NSColor(srgbRed: 0.76, green: 0.40, blue: 0, alpha: 1),
                                   red: NSColor(srgbRed: 0.84, green: 0, blue: 0.08, alpha: 1),
                                   green: NSColor(srgbRed: 0.14, green: 0.54, blue: 0.24, alpha: 1))
        static let dark = Palette(ink: .white, amber: NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1),
                                  red: NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1),
                                  green: NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1))
    }

    static func make(_ st: IconState, refillLit: Int? = nil, dark: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(st, refillLit: refillLit, scale: rect.width / 18, palette: dark ? .dark : .light)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws in an 18-unit, y-down space scaled by `scale`.
    static func draw(_ st: IconState, refillLit: Int?, scale s: CGFloat, palette p: Palette) {
        for i in 0..<8 {
            if st.badge && refillLit == nil && i == 1 { continue }
            let lit = refillLit.map { i < $0 } ?? (i < st.lit)
            let color = lit ? ((st.hot && refillLit == nil) ? p.amber : p.ink) : p.ink.withAlphaComponent(0.25)
            let angle = (-90 + Double(i) * 45) * Double.pi / 180
            let path = NSBezierPath()
            path.move(to: NSPoint(x: (9 + cos(angle) * 4.4) * s, y: (9 + sin(angle) * 4.4) * s))
            path.line(to: NSPoint(x: (9 + cos(angle) * 7.9) * s, y: (9 + sin(angle) * 7.9) * s))
            path.lineWidth = 1.7 * s
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
        let core = refillLit == nil ? st.core : .solid
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        switch core {
        case .solid: p.ink.setFill(); circle(9, 9, 2.1).fill()
        case .amber: p.amber.setFill(); circle(9, 9, 2.1).fill()
        case .red: p.red.setFill(); circle(9, 9, 2.1).fill()
        case .hollow:
            let ring = circle(9, 9, 1.6)
            ring.lineWidth = 1.2 * s
            p.ink.withAlphaComponent(0.6).setStroke()
            ring.stroke()
        }
        if st.badge && refillLit == nil {
            p.green.setFill()
            circle(15, 3, 2.6).fill()
        }
    }
}

struct SparkView: View {
    var state: IconState
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: SparkImage.make(state, dark: scheme == .dark, size: size))
            .frame(width: size, height: size)
    }
}

/// Renders the app icon (a full spark with an amber core on graphite) into an .iconset folder.
enum IconExport {
    static func writeIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                                      ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                                      ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in specs {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let size = CGFloat(px)
            let inset = size * 0.098
            let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
            let tile = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
            NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1),
                       ending: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))?.draw(in: tile, angle: -90)
            let spark = body.width * 0.66
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: body.midX - spark / 2, y: body.midY + spark / 2)
            cg.scaleBy(x: 1, y: -1)
            SparkImage.draw(IconState(core: .amber), refillLit: nil, scale: spark / 18, palette: .dark)
            cg.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("icon_\(name).png"))
            }
        }
    }
}
