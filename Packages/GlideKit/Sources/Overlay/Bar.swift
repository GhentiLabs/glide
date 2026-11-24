import AppKit
import GlideCore
import SwiftUI

/// Where the bar sits: one of eight spots on the screen's edge.
public enum BarAnchor: String, CaseIterable, Sendable {
    case bottom, bottomLeft, bottomRight, top, topLeft, topRight, left, right

    var isVertical: Bool { self == .left || self == .right }

    /// The screen edges the bar touches here.
    var edges: Edge.Set {
        switch self {
        case .bottom: .bottom
        case .bottomLeft: [.bottom, .leading]
        case .bottomRight: [.bottom, .trailing]
        case .top: .top
        case .topLeft: [.top, .leading]
        case .topRight: [.top, .trailing]
        case .left: .leading
        case .right: .trailing
        }
    }

    /// The point on `frame` this anchor sits at.
    func point(in frame: CGRect) -> CGPoint {
        let x = edges.contains(.leading) ? frame.minX : edges.contains(.trailing) ? frame.maxX : frame.midX
        let y = edges.contains(.bottom) ? frame.minY : edges.contains(.top) ? frame.maxY : frame.midY
        return CGPoint(x: x, y: y)
    }

    static func nearest(to point: CGPoint, in frame: CGRect) -> BarAnchor {
        allCases.min { hypot($0.point(in: frame).x - point.x, $0.point(in: frame).y - point.y)
            < hypot($1.point(in: frame).x - point.x, $1.point(in: frame).y - point.y) }!
    }
}

/// What the bar shows. Owned by the app, drawn by `BarPanel`.
@MainActor @Observable
public final class BarModel {
    public var state: SessionState = .idle
    /// Recent microphone levels, oldest first, 0...1.
    public private(set) var levels = [Float](repeating: 0, count: 11)
    var anchor: BarAnchor
    var dragging = false

    public init() {
        anchor = UserDefaults.standard.string(forKey: "barAnchor").flatMap(BarAnchor.init) ?? .bottom
    }

    public func push(level rms: Float) {
        // Speech RMS sits around 0.01–0.2; map it onto 0...1 on a log scale.
        let db = 20 * log10(max(rms, 1e-5))
        levels.removeFirst()
        levels.append(min(max((db + 50) / 40, 0), 1))
    }

    public func resetLevels() { levels = [Float](repeating: 0, count: levels.count) }
}

/// The floating bar: a tab growing out of the screen's edge, dragged to any of eight spots.
/// shortcut: no Dock avoidance or right-click hide menu yet; both arrive in M2.
@MainActor
public final class BarPanel {
    /// Room for the largest bar; the rest of the panel is transparent and clicks pass through it.
    private static let long: CGFloat = 200
    private static let short: CGFloat = 48

    private let panel: NSPanel
    private let model: BarModel
    private var screen: NSScreen? { panel.screen ?? NSScreen.screens.first }

    public init(model: BarModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.long, height: Self.short),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar  // above the Dock and menu bar, so it can sit on the bezel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = NSHostingView(
            rootView: BarView(model: model, onDrag: { [weak self] in self?.drag() }, onDrop: { [weak self] in self?.drop() }))
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place(animated: false) } }
    }

    public func show() {
        place(animated: false)
        panel.orderFrontRegardless()
    }

    private func frame(for anchor: BarAnchor, on screen: NSScreen) -> NSRect {
        let size = anchor.isVertical ? NSSize(width: Self.short, height: Self.long) : NSSize(width: Self.long, height: Self.short)
        let edge = anchor.point(in: screen.frame)
        var origin = NSPoint(
            x: anchor.edges.contains(.leading) ? edge.x : anchor.edges.contains(.trailing) ? edge.x - size.width : edge.x - size.width / 2,
            y: anchor.edges.contains(.bottom) ? edge.y : anchor.edges.contains(.top) ? edge.y - size.height : edge.y - size.height / 2)
        // Top centre hangs below the camera housing on notched displays.
        if anchor == .top { origin.y -= screen.safeAreaInsets.top }
        return NSRect(origin: origin, size: size)
    }

    private func place(animated: Bool) {
        guard let screen else { return }
        let target = frame(for: model.anchor, on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func drag() {
        model.dragging = true
        let mouse = NSEvent.mouseLocation
        panel.setFrame(
            NSRect(x: mouse.x - Self.long / 2, y: mouse.y - Self.short / 2, width: Self.long, height: Self.short),
            display: true)
    }

    private func drop() {
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { $0.frame.contains(mouse) } ?? screen
        if let target { model.anchor = .nearest(to: mouse, in: target.frame) }
        UserDefaults.standard.set(model.anchor.rawValue, forKey: "barAnchor")
        model.dragging = false
        place(animated: true)
    }
}

struct BarView: View {
    let model: BarModel
    let onDrag: () -> Void
    let onDrop: () -> Void
    @State private var hovering = false

    private var edges: Edge.Set { model.dragging ? [] : model.anchor.edges }
    private var vertical: Bool { !model.dragging && model.anchor.isVertical }

    /// Length along the edge and thickness out of it.
    private var size: (length: CGFloat, thickness: CGFloat) {
        switch model.state {
        case .idle, .initializing: model.dragging || hovering ? (56, 22) : (44, 9)
        case .recording, .transcribing: (148, 30)
        case .completed, .error: (60, 24)
        }
    }

    private var alignment: Alignment {
        let h: HorizontalAlignment = edges.contains(.leading) ? .leading : edges.contains(.trailing) ? .trailing : .center
        let v: VerticalAlignment = edges.contains(.bottom) ? .bottom : edges.contains(.top) ? .top : .center
        return Alignment(horizontal: h, vertical: v)
    }

    /// The edge the bar grows out of; nil while it is being dragged.
    private var edge: Edge? {
        guard !model.dragging else { return nil }
        switch model.anchor {
        case .bottom, .bottomLeft, .bottomRight: return .bottom
        case .top, .topLeft, .topRight: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var shape: EdgeTab {
        // A flare where the bar meets the bezel, except at a screen corner, where that end sits flush.
        let along: (start: Edge.Set.Element, end: Edge.Set.Element) = vertical ? (.top, .bottom) : (.leading, .trailing)
        return EdgeTab(
            edge: edge, flareStart: !model.anchor.edges.contains(along.start),
            flareEnd: !model.anchor.edges.contains(along.end), flare: min(6, size.thickness / 2))
    }

    /// Room the flares take beyond the bar's body.
    private var flareRoom: CGFloat {
        guard edge != nil else { return 0 }
        return CGFloat([shape.flareStart, shape.flareEnd].filter { $0 }.count) * shape.flare
    }

    var body: some View {
        content
            .foregroundStyle(.white)
            .frame(
                width: vertical ? size.thickness : size.length + flareRoom,
                height: vertical ? size.length + flareRoom : size.thickness)
            .background(shape.fill(Tokens.barGlass))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
                    .onEnded { _ in onDrop() })
            .animation(Tokens.spring, value: model.state)
            .animation(Tokens.spring, value: hovering)
            .animation(Tokens.spring, value: model.dragging)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .initializing:
            if model.dragging || hovering {
                CaretMark(caret: Tokens.tintGraphic).frame(height: 13).transition(.opacity)
            }
        case .recording:
            HStack(spacing: 3) {
                ForEach(model.levels.indices, id: \.self) { i in
                    Capsule().frame(width: 3, height: 4 + 16 * CGFloat(model.levels[i]))
                }
            }
            .rotationEffect(vertical ? .degrees(90) : .zero)
            .animation(.easeOut(duration: Tokens.levelRelease), value: model.levels)
        case .transcribing:
            Capsule().frame(width: vertical ? 2 : 96, height: vertical ? 96 : 2).opacity(0.7)
        case .completed:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
        case .error:
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
        }
    }

    private var label: String {
        switch model.state {
        case .idle: "Glide is ready"
        case .initializing: "Glide is getting ready"
        case .recording(let handsFree): handsFree ? "Recording hands-free" : "Recording"
        case .transcribing: "Transcribing"
        case .completed: "Text inserted"
        case .error: "Dictation failed"
        }
    }
}

/// A tab growing out of a screen edge: rounded where it stands free, flush and flared where it meets the bezel.
/// With no edge it is a plain capsule.
struct EdgeTab: Shape {
    var edge: Edge?
    var flareStart: Bool
    var flareEnd: Bool
    var flare: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let edge else { return Capsule().path(in: rect) }
        let vertical = edge == .leading || edge == .trailing
        // Drawn as if growing up from the bottom edge, then turned to face the real one.
        let length = vertical ? rect.height : rect.width
        let h = vertical ? rect.width : rect.height
        let r = h / 2
        let x0 = flareStart ? flare : 0
        let x1 = length - (flareEnd ? flare : 0)
        var p = Path()
        if flareStart {
            p.move(to: CGPoint(x: 0, y: h))
            p.addQuadCurve(to: CGPoint(x: x0, y: h - flare), control: CGPoint(x: x0, y: h))
            p.addArc(tangent1End: CGPoint(x: x0, y: 0), tangent2End: CGPoint(x: x0 + r, y: 0), radius: r)
        } else {
            p.move(to: CGPoint(x: 0, y: h))
            p.addLine(to: .zero)
        }
        if flareEnd {
            p.addArc(tangent1End: CGPoint(x: x1, y: 0), tangent2End: CGPoint(x: x1, y: r), radius: r)
            p.addLine(to: CGPoint(x: x1, y: h - flare))
            p.addQuadCurve(to: CGPoint(x: length, y: h), control: CGPoint(x: x1, y: h))
        } else {
            p.addLine(to: CGPoint(x: length, y: 0))
            p.addLine(to: CGPoint(x: length, y: h))
        }
        p.closeSubpath()
        let turn: CGAffineTransform = switch edge {
        case .bottom: .identity
        case .top: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leading: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .trailing: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
        return p.applying(turn).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
