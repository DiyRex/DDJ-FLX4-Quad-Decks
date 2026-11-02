import AppKit

struct OverlayModel {
    var active = [0, 1]
    var decks = [DeckInfo](repeating: .init(), count: 4)
    var pickup: [[String]] = [[], []]
    var status: String? = nil      // shown when something needs attention
}

enum DeckColors {
    static let all: [NSColor] = [
        NSColor(srgbRed: 0.25, green: 0.66, blue: 1.00, alpha: 1),  // 1 blue
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.15, alpha: 1),  // 2 orange
        NSColor(srgbRed: 0.40, green: 0.86, blue: 0.35, alpha: 1),  // 3 green
        NSColor(srgbRed: 0.88, green: 0.40, blue: 1.00, alpha: 1),  // 4 magenta
    ]
}

/// Two small pills, one per FLX4 side. `.notch` parks them either side of the MacBook notch
/// (the black strip rekordbox never draws into); `.free` lets you drag the pair anywhere.
final class OverlayController {
    enum Placement: String { case notch, free }
    static let sizes: [(String, CGFloat)] = [("Small", 0.85), ("Medium", 1.0), ("Large", 1.3)]

    var model = OverlayModel() { didSet { views.forEach { $0.model = model } } }
    var onSelectDeck: ((Int, Int) -> Void)?
    private(set) var visible = false

    var placement: Placement {
        get { Placement(rawValue: UserDefaults.standard.string(forKey: "placement") ?? "") ?? .notch }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "placement"); layout() }
    }
    var scale: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "scale"); return v > 0 ? v : 1.0 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "scale"); layout() }
    }
    private var freeOrigin: NSPoint? {
        get { UserDefaults.standard.string(forKey: "freeOrigin").map { NSPointFromString($0) } }
        set { UserDefaults.standard.set(newValue.map { NSStringFromPoint($0) }, forKey: "freeOrigin") }
    }

    private let panels: [NSPanel]
    private let views: [SideView]

    init() {
        views = [SideView(side: 0), SideView(side: 1)]
        panels = views.map { v in
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)  // above the menu bar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.contentView = v
            return p
        }
        for v in views {
            v.controller = self
            v.onSelect = { [weak self] side, deck in self?.onSelectDeck?(side, deck) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }
    }

    func show(_ on: Bool) {
        visible = on
        if on { layout(); panels.forEach { $0.orderFrontRegardless() } } else { panels.forEach { $0.orderOut(nil) } }
    }

    func flash(_ side: Int) { views[side].flash() }

    /// Screen with the notch if there is one, else the main screen.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func layout() {
        guard let s = screen else { return }
        let notchH = s.safeAreaInsets.top
        let h = round((notchH > 0 ? notchH : 30) * (placement == .notch ? 1 : scale) * (placement == .notch ? max(scale, 1) : 1))
        let w = round(h * 4.4 * (placement == .notch ? scale / max(scale, 1) : 1))
        let gap: CGFloat = 6
        var frames: [NSRect]
        if placement == .notch, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let y = s.frame.maxY - h
            frames = [NSRect(x: l.maxX - w - gap, y: y, width: w, height: h),
                      NSRect(x: r.minX + gap, y: y, width: w, height: h)]
        } else {
            let o = placement == .free ? (freeOrigin ?? defaultFreeOrigin(s, w: w, h: h))
                                       : NSPoint(x: s.frame.midX - w - gap, y: s.frame.maxY - h)
            frames = [NSRect(x: o.x, y: o.y, width: w, height: h),
                      NSRect(x: o.x + w + gap * 2, y: o.y, width: w, height: h)]
        }
        for (p, f) in zip(panels, frames) { p.setFrame(f, display: true) }
        views.forEach { $0.needsDisplay = true }
    }

    private func defaultFreeOrigin(_ s: NSScreen, w: CGFloat, h: CGFloat) -> NSPoint {
        NSPoint(x: s.visibleFrame.midX - w - 6, y: s.visibleFrame.maxY - h - 8)
    }

    /// Dragging either pill moves the pair (free placement only).
    func drag(by d: NSPoint) {
        guard placement == .free else { return }
        let o = panels[0].frame.origin
        freeOrigin = NSPoint(x: o.x + d.x, y: o.y + d.y)
        layout()
    }
}

final class SideView: NSView {
    let side: Int
    weak var controller: OverlayController?
    var onSelect: ((Int, Int) -> Void)?
    var model = OverlayModel() { didSet { needsDisplay = true } }
    private var flashAt: CFTimeInterval = 0
    private var chips: [(NSRect, Int)] = []
    private var dragStart: NSPoint?
    private var dragged = false

    init(side: Int) { self.side = side; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func flash() { flashAt = CACurrentMediaTime() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) { dragStart = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let now = NSEvent.mouseLocation
        if !dragged && hypot(now.x - s.x, now.y - s.y) < 3 { return }
        dragged = true
        controller?.drag(by: NSPoint(x: now.x - s.x, y: now.y - s.y))
        dragStart = now
    }
    override func mouseUp(with e: NSEvent) {
        defer { dragStart = nil }
        guard !dragged else { return }
        let p = convert(e.locationInWindow, from: nil)
        if let hit = chips.first(where: { $0.0.contains(p) }) { onSelect?(side, hit.1) }
    }

    override func draw(_ dirty: NSRect) {
        chips = []
        let b = bounds, h = b.height, deck = model.active[side], color = DeckColors.all[deck]
        let age = CACurrentMediaTime() - flashAt
        let glow = age < 0.5 ? CGFloat(1 - age / 0.5) : 0

        // Pill hangs from the top edge: square top, rounded bottom (matches the notch).
        let pill = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: h * 0.32, yRadius: h * 0.32)
        NSColor.black.withAlphaComponent(0.92).setFill(); pill.fill()
        color.withAlphaComponent(0.35 + 0.65 * glow).setStroke(); pill.lineWidth = 1 + 1.5 * glow; pill.stroke()

        if side == 0, let s = model.status {   // problems take over the left pill
            label(s, NSRect(x: h * 0.3, y: 0, width: b.width - h * 0.6, height: h), size: h * 0.30,
                  weight: .semibold, color: .systemYellow, align: .center)
            return
        }

        let pad = h * 0.16, chipH = h - pad * 2, chipW = h * 1.35
        let tag = side == 0 ? "L" : "R"
        label(tag, NSRect(x: pad, y: 0, width: h * 0.45, height: h), size: h * 0.34, weight: .heavy,
              color: NSColor(white: 1, alpha: 0.45), align: .center)
        var x = pad + h * 0.5
        for d in [side, side + 2] {
            let r = NSRect(x: x, y: pad, width: chipW, height: chipH)
            chips.append((r, d))
            drawChip(r, deck: d, on: d == deck)
            x += chipW + pad
        }
        // Right of the chips: pickup warning, else a play state summary of the hidden deck.
        let info = NSRect(x: x, y: 0, width: b.width - x - pad, height: h)
        if !model.pickup[side].isEmpty {
            label("⇕ " + model.pickup[side].joined(separator: " "), info, size: h * 0.26, weight: .bold,
                  color: .systemYellow, align: .left)
        } else if model.decks[deck ^ 2].playing {
            label("\(deck ^ 2 + 1) ▶", info, size: h * 0.28, weight: .bold,
                  color: DeckColors.all[deck ^ 2].withAlphaComponent(0.85), align: .left)
        }
    }

    private func drawChip(_ r: NSRect, deck d: Int, on: Bool) {
        let c = DeckColors.all[d], info = model.decks[d], h = r.height
        let p = NSBezierPath(roundedRect: r, xRadius: h * 0.25, yRadius: h * 0.25)
        (on ? c : NSColor(white: 1, alpha: 0.05)).setFill(); p.fill()
        c.withAlphaComponent(on ? 1 : 0.45).setStroke(); p.lineWidth = 1; p.stroke()
        let fg = on ? NSColor.black : c.withAlphaComponent(0.8)
        label("\(d + 1)", NSRect(x: r.minX + h * 0.18, y: r.minY, width: h * 0.6, height: h * 0.86),
              size: h * 0.62, weight: .heavy, color: fg, align: .left)
        let glyph = info.playing ? "▶" : (info.loaded ? "●" : "")
        label(glyph, NSRect(x: r.maxX - h * 0.62, y: r.minY, width: h * 0.5, height: h * 0.86),
              size: h * (info.playing ? 0.36 : 0.26), weight: .bold, color: fg, align: .center)
        // level meter along the bottom of the chip
        let lv = CGFloat(info.level) / 127, t = NSRect(x: r.minX + 3, y: r.maxY - 4, width: r.width - 6, height: 2)
        NSColor(white: on ? 0 : 1, alpha: 0.2).setFill(); NSBezierPath(rect: t).fill()
        (on ? NSColor.black : c).setFill(); NSBezierPath(rect: NSRect(x: t.minX, y: t.minY, width: t.width * lv, height: 2)).fill()
    }

    private func label(_ s: String, _ r: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment) {
        let ps = NSMutableParagraphStyle(); ps.alignment = align; ps.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
        let th = font.ascender - font.descender
        (s as NSString).draw(in: NSRect(x: r.minX, y: r.midY - th / 2, width: r.width, height: th), withAttributes: attrs)
    }
}
