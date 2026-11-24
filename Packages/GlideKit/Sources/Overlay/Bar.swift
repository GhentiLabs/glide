import AppKit
import GlideCore
import SwiftUI

/// What the bar and its popups show. Owned by the app, drawn by `BarPanel`.
@MainActor @Observable
public final class BarModel {
    public var state: SessionState = .idle {
        didSet {
            if state != oldValue { stateChanged = .now }
            if !isBusy { showNextPending() }
        }
    }
    /// Smoothed microphone level, 0...1.
    public private(set) var level: Float = 0
    /// Recent levels, newest last; the waveform ripples them outward from its centre.
    private(set) var levels: [Float] = []
    /// 0...1 while the speech model loads; shown in the hover hint.
    public var progress: Double?
    public var paused = false
    /// The popup on screen, if any.
    public private(set) var toast: Toast?
    /// Seconds left before the toast closes itself.
    public private(set) var toastRemaining: TimeInterval = 0
    public var toastPaused = false
    public private(set) var hiddenUntil: Date?
    /// Shown in the hover hint.
    public var hotkeyName = "fn"

    public var onStop: () -> Void = {}
    public var onCancel: () -> Void = {}
    public var onOpenSettings: () -> Void = {}

    var anchor: BarAnchor
    var dragging = false
    /// Where the bar will land if dropped now.
    var preview: BarAnchor?
    /// How far the bar's centre is from the popup's, so a tip's pointer can aim at it.
    var pointerShift: CGFloat = 0
    private(set) var stateChanged = Date.now
    @ObservationIgnored private var pending: [Toast] = []
    @ObservationIgnored private var lastLevelTime = Date.now
    @ObservationIgnored private var lastHistoryTime = Date.now
    @ObservationIgnored private var countdown: Task<Void, Never>?

    public init() {
        anchor = UserDefaults.standard.string(forKey: "barAnchor").flatMap(BarAnchor.init) ?? .bottom
    }

    var isBusy: Bool {
        switch state {
        case .recording, .transcribing, .initializing: true
        default: false
        }
    }

    var isHidden: Bool { hiddenUntil.map { $0 > .now } ?? false }

    /// Feed one buffer's RMS. Attack is fast and release slow, so bars jump on speech and settle in silence.
    public func push(level rms: Float) {
        let now = Date.now
        let dt = Float(now.timeIntervalSince(lastLevelTime))
        lastLevelTime = now
        // The speech range, −50 to −10 dB, mapped onto 0...1.
        let target = min(max((20 * log10(max(rms, 1e-5)) + 50) / 40, 0), 1)
        let tau = Float(target > level ? Tokens.levelAttack : Tokens.levelRelease)
        level += (target - level) * (1 - exp(-dt / tau))
        if now.timeIntervalSince(lastHistoryTime) >= 0.06 {
            lastHistoryTime = now
            levels = Array((levels + [level]).suffix(6))
        }
    }

    public func resetLevel() {
        level = 0
        levels = []
    }

    public func hide(for seconds: TimeInterval) {
        let until = Date.now.addingTimeInterval(seconds)
        hiddenUntil = until
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if hiddenUntil == until { hiddenUntil = nil }
        }
    }

    public func unhide() { hiddenUntil = nil }

    /// Alerts replace whatever is showing. Tips wait until Glide is idle and nothing else is showing.
    public func show(_ toast: Toast) {
        if toast.kind == .alert || (self.toast == nil && !isBusy) {
            present(toast)
        } else {
            pending.append(toast)
        }
    }

    public func dismissToast() {
        countdown?.cancel()
        toast = nil
        showNextPending()
    }

    private func showNextPending() {
        guard toast == nil, !isBusy, !pending.isEmpty else { return }
        present(pending.removeFirst())
    }

    private func present(_ toast: Toast) {
        countdown?.cancel()
        self.toast = toast
        toastRemaining = toast.duration
        toastPaused = false
        countdown = Task {
            while toastRemaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if !toastPaused { toastRemaining -= 0.1 }
            }
            if self.toast?.id == toast.id { dismissToast() }
        }
    }
}

/// A popup tied to the bar: an alert (bar toast) or a tip (pointer bubble with a countdown).
public struct Toast: Identifiable {
    public enum Kind { case alert, tip }

    public struct Action {
        public var label: String
        public var primary: Bool
        public var run: @MainActor () -> Void

        public init(_ label: String, primary: Bool = false, run: @escaping @MainActor () -> Void) {
            self.label = label
            self.primary = primary
            self.run = run
        }
    }

    public let id = UUID()
    public var kind: Kind
    public var symbol: String
    public var title: String
    public var message: String?
    /// A key or shortcut drawn as a key cap.
    public var keycap: String?
    public var actions: [Action]
    public var duration: TimeInterval

    public init(
        _ kind: Kind = .alert, symbol: String, title: String, message: String? = nil, keycap: String? = nil,
        actions: [Action] = [], duration: TimeInterval = 5
    ) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.message = message
        self.keycap = keycap
        self.actions = actions
        self.duration = duration
    }
}

/// The floating bar, the popup panel beside it, and the snap target shown while dragging.
@MainActor
public final class BarPanel {
    /// Room for the largest bar and its shadow; the rest of the panel is transparent and clicks pass through it.
    private static let long: CGFloat = 240
    private static let short: CGFloat = 52
    /// Fixed, with room for a long message; clicks pass through the transparent part.
    private static let popupSize = NSSize(width: 340, height: 260)

    private let panel: NSPanel
    private let popup: NSPanel
    private let preview: NSPanel
    private let model: BarModel
    private var screen: NSScreen? { panel.screen ?? NSScreen.screens.first }

    public init(model: BarModel) {
        self.model = model
        panel = Self.makePanel(size: NSSize(width: Self.long, height: Self.short))
        popup = Self.makePanel(size: Self.popupSize)
        preview = Self.makePanel(size: NSSize(width: Self.long, height: Self.short))
        preview.ignoresMouseEvents = true
        panel.contentView = Self.host(
            BarView(model: model, onDrag: { [weak self] in self?.drag() }, onDrop: { [weak self] in self?.drop() }))
        popup.contentView = Self.host(PopupView(model: model))
        preview.contentView = Self.host(SnapPreview(model: model))
        // shortcut: the Dock moving or resizing without a screen change isn't noticed until the next drop or relaunch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place(animated: false) } }
    }

    /// A hosting view that leaves the panel's size to us; by default it resizes the window to fit its content.
    static func host(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar  // above the menu bar, so the bar can sit on the top bezel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        return panel
    }

    public func show() {
        place(animated: false)
        panel.orderFrontRegardless()
        popup.orderFrontRegardless()
        preview.orderFrontRegardless()
    }

    /// The screen without the Dock, so the bar sits on top of it rather than over its icons.
    /// The menu bar stays in: the bar may hang from the top bezel.
    private func area(of screen: NSScreen) -> NSRect {
        var area = screen.visibleFrame
        area.size.height = screen.frame.maxY - area.minY
        return area
    }

    private func frame(for anchor: BarAnchor, on screen: NSScreen) -> NSRect {
        let size = anchor.isVertical ? NSSize(width: Self.short, height: Self.long) : NSSize(width: Self.long, height: Self.short)
        let edge = anchor.point(in: area(of: screen))
        var origin = NSPoint(
            x: anchor.edges.contains(.leading) ? edge.x : anchor.edges.contains(.trailing) ? edge.x - size.width : edge.x - size.width / 2,
            y: anchor.edges.contains(.bottom) ? edge.y : anchor.edges.contains(.top) ? edge.y - size.height : edge.y - size.height / 2)
        // Top centre hangs below the camera housing on notched displays.
        if anchor == .top { origin.y -= screen.safeAreaInsets.top }
        return NSRect(origin: origin, size: size)
    }

    /// The popup sits on the screen side of the bar, kept on screen.
    private func popupFrame(beside bar: NSRect, anchor: BarAnchor, on screen: NSScreen) -> NSRect {
        let size = Self.popupSize
        let gap: CGFloat = 40
        var origin: NSPoint
        switch anchor {
        case .left: origin = NSPoint(x: bar.minX + gap, y: bar.midY - size.height / 2)
        case .right: origin = NSPoint(x: bar.maxX - gap - size.width, y: bar.midY - size.height / 2)
        case .top, .topLeft, .topRight: origin = NSPoint(x: bar.midX - size.width / 2, y: bar.maxY - gap - size.height)
        default: origin = NSPoint(x: bar.midX - size.width / 2, y: bar.minY + gap)
        }
        let visible = area(of: screen)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(origin: origin, size: size)
    }

    private func place(animated: Bool) {
        guard let screen else { return }
        let anchor = model.anchor
        let target = frame(for: anchor, on: screen)
        let popupFrame = popupFrame(beside: target, anchor: anchor, on: screen)
        popup.setFrame(popupFrame, display: true)
        // The idle bar's centre sits about 30 pt in from a screen corner.
        let barX = anchor.edges.contains(.leading) ? target.minX + 30 : anchor.edges.contains(.trailing) ? target.maxX - 30 : target.midX
        model.pointerShift = anchor.isVertical ? 0 : barX - popupFrame.midX
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

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? screen
    }

    private func drag() {
        model.dragging = true
        let mouse = NSEvent.mouseLocation
        panel.setFrame(
            NSRect(x: mouse.x - Self.long / 2, y: mouse.y - Self.short / 2, width: Self.long, height: Self.short),
            display: true)
        guard let target = screen(at: mouse) else { return }
        let next = BarAnchor.nearest(to: mouse, in: area(of: target))
        if next != model.preview {
            preview.setFrame(frame(for: next, on: target), display: true)
            model.preview = next
        }
    }

    private func drop() {
        let mouse = NSEvent.mouseLocation
        if let target = screen(at: mouse) { model.anchor = .nearest(to: mouse, in: area(of: target)) }
        UserDefaults.standard.set(model.anchor.rawValue, forKey: "barAnchor")
        model.dragging = false
        model.preview = nil
        place(animated: true)
    }
}

/// The bar and every popup: dark glass in both appearances, with a hairline highlight and a soft shadow.
struct Glass<S: Shape>: View {
    let shape: S
    /// Washes the glass, for errors and the latched hands-free state.
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let strong = contrast == .increased
        ZStack {
            if reduceTransparency {
                shape.fill(Color(white: 0.1))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Tokens.barGlass.opacity(0.6))
            }
            if let tint { shape.fill(tint.opacity(0.25)) }
        }
        .overlay(shape.stroke(tint ?? .white, lineWidth: strong ? 1 : 0.5).opacity(tint != nil ? 0.9 : strong ? 0.5 : 0.2))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.3), radius: 5, y: 1)
    }
}

struct BarView: View {
    let model: BarModel
    let onDrag: () -> Void
    let onDrop: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var vertical: Bool { !model.dragging && model.anchor.isVertical }
    private var handsFree: Bool { model.state == .recording(handsFree: true) }
    private var hidden: Bool { model.isHidden && model.state == .idle && !hovering }
    private var isError: Bool {
        if case .error = model.state { return true }
        return false
    }

    /// Length along the edge and thickness out of it.
    private var size: (length: CGFloat, thickness: CGFloat) {
        if hidden { return (32, 3) }
        switch model.state {
        case .idle: return model.dragging ? (56, 22) : hovering ? (vertical ? (24, 56) : (136, 24)) : (44, 9)
        case .initializing, .transcribing: return (148, 30)
        case .recording(let handsFree): return handsFree ? (212, 36) : (148, 30)
        case .completed, .error: return (60, 24)
        }
    }

    private var edge: Edge? { model.dragging ? nil : model.anchor.edge }

    private var shape: EdgeTab {
        // A flare where the bar meets the bezel, except at a screen corner, where that end sits flush.
        let along: (start: Edge.Set.Element, end: Edge.Set.Element) = vertical ? (.top, .bottom) : (.leading, .trailing)
        return EdgeTab(
            edge: edge, flareStart: !model.anchor.edges.contains(along.start),
            flareEnd: !model.anchor.edges.contains(along.end), flare: min(6, size.thickness / 2))
    }

    private var flareRoom: CGFloat {
        guard edge != nil else { return 0 }
        return CGFloat([shape.flareStart, shape.flareEnd].filter { $0 }.count) * shape.flare
    }

    private var hint: String {
        if model.paused { return "Paused" }
        if let progress = model.progress { return "Loading \(Int(progress * 100))%" }
        return "Ready"
    }

    var body: some View {
        let vertical = vertical
        content
            .foregroundStyle(.white)
            .frame(
                width: vertical ? size.thickness : size.length + flareRoom,
                height: vertical ? size.length + flareRoom : size.thickness)
            .background(Glass(shape: shape, tint: isError ? .red : handsFree ? Tokens.tintGraphic : nil))
            .brightness(model.state == .completed ? 0.12 : 0)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: isError) { view, offset in
                view.offset(x: vertical ? 0 : offset, y: vertical ? offset : 0)
            } keyframes: { _ in
                // Shakes on the way into an error only.
                let amount: CGFloat = isError && !reduceMotion ? 1 : 0
                KeyframeTrack {
                    CubicKeyframe(-5 * amount, duration: 0.05)
                    CubicKeyframe(5 * amount, duration: 0.08)
                    CubicKeyframe(-3 * amount, duration: 0.08)
                    CubicKeyframe(0, duration: 0.08)
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
                    .onEnded { _ in onDrop() })
            .contextMenu {
                if model.isHidden {
                    Button("Show Glide") { model.unhide() }
                } else {
                    Button("Hide for 10 Minutes") { model.hide(for: 600) }
                    Button("Hide for 1 Hour") { model.hide(for: 3600) }
                }
                Divider()
                Button("Settings…") { model.onOpenSettings() }
            }
            .opacity(hidden ? 0.45 : 1)
            .animation(Tokens.spring, value: model.state)
            .animation(Tokens.spring, value: hovering)
            .animation(Tokens.spring, value: model.dragging)
            .animation(Tokens.spring, value: hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.dragging ? .center : model.anchor.alignment)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            if model.dragging || (hovering && vertical) {
                CaretMark(caret: Tokens.tintGraphic).frame(height: 13).transition(.opacity)
            } else if hovering {
                HStack(spacing: 7) {
                    CaretMark(caret: Tokens.tintGraphic).frame(height: 13)
                    Keycap(model.hotkeyName, size: 10)
                    Text(hint).font(.system(size: 11, weight: .medium)).opacity(0.75).fixedSize()
                }
                .transition(.opacity)
            }
        case .initializing, .transcribing, .recording:
            let stack = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
            stack {
                if handsFree { barButton("xmark", label: "Cancel", action: model.onCancel) }
                Waveform(model: model, vertical: vertical)
                if handsFree { barButton("stop.fill", label: "Stop and insert", action: model.onStop) }
            }
        case .completed:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .error:
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch model.state {
        case .idle: model.isHidden ? "Glide is hidden" : "Glide is ready. Hold \(model.hotkeyName) to dictate."
        case .initializing: "Glide is getting ready"
        case .recording(let handsFree): handsFree ? "Recording hands-free" : "Recording"
        case .transcribing: "Transcribing"
        case .completed: "Text inserted"
        case .error: "Dictation failed"
        }
    }
}

/// While dragging, a ghost of the bar where it will land.
struct SnapPreview: View {
    let model: BarModel

    var body: some View {
        ZStack {
            if let anchor = model.preview {
                let vertical = anchor.isVertical
                EdgeTab(edge: anchor.edge, flareStart: false, flareEnd: false, flare: 0)
                    .fill(Tokens.tintGraphic.opacity(0.35))
                    .overlay(EdgeTab(edge: anchor.edge, flareStart: false, flareEnd: false, flare: 0).stroke(Tokens.tintGraphic, lineWidth: 1))
                    .frame(width: vertical ? 12 : 60, height: vertical ? 60 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor.alignment)
                    .transition(.opacity)
            }
        }
        .animation(Tokens.spring, value: model.preview)
    }
}

/// Eleven bars following the voice. Recent levels ripple out from the centre, so speech looks uneven and alive.
struct Waveform: View {
    let model: BarModel
    let vertical: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion && model.state != .recording(handsFree: false))) { context in
            let now = context.date
            let bars = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
            bars {
                ForEach(0..<11, id: \.self) { i in
                    let value = level(i, at: now)
                    let length = 3 + 17 * CGFloat(value)
                    Capsule()
                        .fill(model.state.isRecording && value > 0.7 ? Tokens.tintGraphic : .white)
                        .frame(width: vertical ? length : 3, height: vertical ? 3 : length)
                        .opacity(barOpacity(i, at: now))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 0...1 for bar `i`.
    private func level(_ i: Int, at now: Date) -> Double {
        let phase = now.timeIntervalSinceReferenceDate
        let taper = 0.55 + 0.45 * cos(Double(i - 5) / 5 * .pi / 2)
        // The centre bar is the newest level; each step out is one sample older.
        let history = model.levels
        let lag = abs(i - 5)
        let heard = lag < history.count ? Double(history[history.count - 1 - lag]) : 0
        switch model.state {
        case .recording:
            let jitter = reduceMotion ? 1 : 0.8 + 0.2 * sin(phase * (5 + Double(i % 3)) + Double(i) * 1.7)
            return min(1, heard * taper * jitter + 0.04)
        case .transcribing:
            // Freeze the last shape and ease it down under the sweep.
            let t = min(1, now.timeIntervalSince(model.stateChanged) / 0.2)
            return heard * taper * (1 - t) * (1 - t)
        case .initializing:
            return reduceMotion ? 0 : 0.06 * (1 + sin(phase * 3 + Double(i) * 0.5))
        default:
            return 0
        }
    }

    private func barOpacity(_ i: Int, at now: Date) -> Double {
        guard model.state == .transcribing, !reduceMotion else { return 1 }
        // A highlight gliding along the row until text arrives.
        let position = (now.timeIntervalSinceReferenceDate * 1.2).truncatingRemainder(dividingBy: 1) * 14 - 1.5
        return 0.35 + 0.65 * max(0, 1 - abs(Double(i) - position) / 2.5)
    }
}

extension SessionState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// A popup card; tips carry a pointer aimed at the bar.
struct Bubble: Shape {
    var pointer: Edge?
    var shift: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: Tokens.popupRadius)
        guard let pointer else { return body }
        let half: CGFloat = 8, depth: CGFloat = 7
        let limit = (pointer == .leading || pointer == .trailing ? rect.height : rect.width) / 2 - Tokens.popupRadius - half
        let s = min(max(shift, -limit), limit)
        let (base1, tip, base2): (CGPoint, CGPoint, CGPoint) = switch pointer {
        case .bottom: (CGPoint(x: rect.midX + s - half, y: rect.maxY), CGPoint(x: rect.midX + s, y: rect.maxY + depth), CGPoint(x: rect.midX + s + half, y: rect.maxY))
        case .top: (CGPoint(x: rect.midX + s - half, y: rect.minY), CGPoint(x: rect.midX + s, y: rect.minY - depth), CGPoint(x: rect.midX + s + half, y: rect.minY))
        case .leading: (CGPoint(x: rect.minX, y: rect.midY - half), CGPoint(x: rect.minX - depth, y: rect.midY), CGPoint(x: rect.minX, y: rect.midY + half))
        case .trailing: (CGPoint(x: rect.maxX, y: rect.midY - half), CGPoint(x: rect.maxX + depth, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY + half))
        }
        var point = Path()
        point.move(to: base1)
        point.addLine(to: tip)
        point.addLine(to: base2)
        point.closeSubpath()
        return body.union(point)
    }
}

/// The current toast: a card that grows out of the bar and retreats into it.
struct PopupView: View {
    let model: BarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The side of the card that faces the bar.
    private var facing: Edge {
        switch model.anchor {
        case .left: .leading
        case .right: .trailing
        case .top, .topLeft, .topRight: .top
        default: .bottom
        }
    }

    private var alignment: Alignment {
        switch facing {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private var emerge: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let anchor: UnitPoint = switch facing {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
        let (x, y): (CGFloat, CGFloat) = switch facing {
        case .leading: (-12, 0)
        case .trailing: (12, 0)
        case .top: (0, -12)
        case .bottom: (0, 12)
        }
        return .opacity.combined(with: .scale(scale: 0.9, anchor: anchor)).combined(with: .offset(x: x, y: y))
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if let toast = model.toast {
                card(toast)
                    .transition(emerge)
                    .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(10)
        .animation(Tokens.spring, value: model.toast?.id)
    }

    private func card(_ toast: Toast) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: toast.symbol).foregroundStyle(toast.kind == .tip ? Tokens.tintGraphic : .white.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(toast.title).font(.system(size: 13, weight: .semibold))
                    if let message = toast.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                            .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button { model.dismissToast() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if toast.keycap != nil || !toast.actions.isEmpty {
                HStack(spacing: 8) {
                    if let keycap = toast.keycap { Keycap(keycap, size: 11) }
                    Spacer(minLength: 0)
                    ForEach(toast.actions.indices, id: \.self) { i in
                        let action = toast.actions[i]
                        Button(action.label) {
                            action.run()
                            model.dismissToast()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(action.primary ? Tokens.tint : .white.opacity(0.14)))
                    }
                }
            }
            if toast.kind == .tip {
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.35))
                        .frame(width: proxy.size.width * max(0, model.toastRemaining / toast.duration))
                }
                .frame(height: 2)
                .animation(.linear(duration: 0.1), value: model.toastRemaining)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 316, alignment: .leading)
        .background(Glass(shape: Bubble(pointer: toast.kind == .tip ? facing : nil, shift: model.pointerShift)))
        .onHover { model.toastPaused = $0 }
        .accessibilityElement(children: .contain)
    }
}

/// The live bar drawn inside a window, so first run can show what to look for at the screen edge.
public struct BarPreview: View {
    let model: BarModel

    public init(model: BarModel) { self.model = model }

    public var body: some View {
        BarView(model: model, onDrag: {}, onDrop: {})
            .frame(width: 240, height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
            .accessibilityLabel("The Glide bar")
    }
}
