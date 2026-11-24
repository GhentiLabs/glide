import AppKit
import GlideCore
import SwiftUI

/// What the bar and its popups show. Owned by the app, drawn by `BarPanel`.
@MainActor @Observable
public final class BarModel {
    public var state: SessionState = .idle {
        didSet { if !isBusy { showNextPending() } }
    }
    /// Smoothed microphone level, 0...1.
    public private(set) var level: Float = 0
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
    @ObservationIgnored private var pending: [Toast] = []
    @ObservationIgnored private var lastLevelTime = Date.now
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
    }

    public func resetLevel() { level = 0 }

    public func hide(for seconds: TimeInterval) {
        let until = Date.now.addingTimeInterval(seconds)
        hiddenUntil = until
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if hiddenUntil == until { hiddenUntil = nil }
        }
    }

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

/// The floating bar and the popup panel beside it.
/// shortcut: no Dock avoidance (the bar sits on the bezel by design) and no snap-target highlight while dragging.
@MainActor
public final class BarPanel {
    /// Room for the largest bar; the rest of the panel is transparent and clicks pass through it.
    private static let long: CGFloat = 220
    private static let short: CGFloat = 48
    private static let popupSize = NSSize(width: 340, height: 170)

    private let panel: NSPanel
    private let popup: NSPanel
    private let model: BarModel
    private var screen: NSScreen? { panel.screen ?? NSScreen.screens.first }

    public init(model: BarModel) {
        self.model = model
        panel = Self.makePanel(size: NSSize(width: Self.long, height: Self.short))
        popup = Self.makePanel(size: Self.popupSize)
        panel.contentView = Self.host(
            BarView(model: model, onDrag: { [weak self] in self?.drag() }, onDrop: { [weak self] in self?.drop() }))
        popup.contentView = Self.host(PopupView(model: model))
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
        panel.level = .statusBar  // above the Dock and menu bar, so the bar can sit on the bezel
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

    /// The popup sits on the screen side of the bar, clear of it, kept on screen.
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
        let visible = screen.frame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(origin: origin, size: size)
    }

    private func place(animated: Bool) {
        guard let screen else { return }
        let target = frame(for: model.anchor, on: screen)
        popup.setFrame(popupFrame(beside: target, anchor: model.anchor, on: screen), display: true)
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

    private var vertical: Bool { !model.dragging && model.anchor.isVertical }
    private var handsFree: Bool { model.state == .recording(handsFree: true) }

    /// Length along the edge and thickness out of it.
    private var size: (length: CGFloat, thickness: CGFloat) {
        switch model.state {
        case .idle: model.dragging ? (56, 22) : hovering ? (76, 22) : (44, 9)
        case .initializing, .transcribing: (148, 30)
        case .recording(let handsFree): handsFree ? (196, 30) : (148, 30)
        case .completed, .error: (60, 24)
        }
    }

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

    private var flareRoom: CGFloat {
        guard edge != nil else { return 0 }
        return CGFloat([shape.flareStart, shape.flareEnd].filter { $0 }.count) * shape.flare
    }

    private var alignment: Alignment {
        let edges: Edge.Set = model.dragging ? [] : model.anchor.edges
        let h: HorizontalAlignment = edges.contains(.leading) ? .leading : edges.contains(.trailing) ? .trailing : .center
        let v: VerticalAlignment = edges.contains(.bottom) ? .bottom : edges.contains(.top) ? .top : .center
        return Alignment(horizontal: h, vertical: v)
    }

    private var fill: Color {
        if case .error = model.state { return Color(red: 0.62, green: 0.13, blue: 0.11).opacity(0.92) }
        return Tokens.barGlass
    }

    var body: some View {
        let hidden = model.isHidden && model.state == .idle
        content
            .foregroundStyle(.white)
            .frame(
                width: vertical ? size.thickness : size.length + flareRoom,
                height: vertical ? size.length + flareRoom : size.thickness)
            .background(shape.fill(fill))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in onDrag() }
                    .onEnded { _ in onDrop() })
            .contextMenu {
                Button("Hide for 10 Minutes") { model.hide(for: 600) }
                Button("Hide for 1 Hour") { model.hide(for: 3600) }
                Divider()
                Button("Settings…") { model.onOpenSettings() }
            }
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(Tokens.spring, value: model.state)
            .animation(Tokens.spring, value: hovering)
            .animation(Tokens.spring, value: model.dragging)
            .animation(Tokens.spring, value: hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            if model.dragging || hovering {
                HStack(spacing: 6) {
                    CaretMark(caret: Tokens.tintGraphic).frame(height: 13)
                    if hovering && !model.dragging { Text(model.hotkeyName).font(.system(size: 10, weight: .semibold)).opacity(0.7) }
                }
                .transition(.opacity)
            }
        case .initializing, .transcribing, .recording:
            let stack = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
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
        }
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch model.state {
        case .idle: "Glide is ready. Hold \(model.hotkeyName) to dictate."
        case .initializing: "Glide is getting ready"
        case .recording(let handsFree): handsFree ? "Recording hands-free" : "Recording"
        case .transcribing: "Transcribing"
        case .completed: "Text inserted"
        case .error: "Dictation failed"
        }
    }
}

/// Eleven bars following the voice, with a quiet breathing floor; a sweep while transcribing.
struct Waveform: View {
    let model: BarModel
    let vertical: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion && model.state != .recording(handsFree: false))) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let bars = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
            bars {
                ForEach(0..<11, id: \.self) { i in
                    let length = barLength(i, phase: phase)
                    Capsule()
                        .frame(width: vertical ? length : 3, height: vertical ? 3 : length)
                        .opacity(barOpacity(i, phase: phase))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func barLength(_ i: Int, phase: Double) -> CGFloat {
        switch model.state {
        case .recording:
            // Centre bars weigh more; a small phase term keeps the row alive.
            let weight = 0.45 + 0.55 * cos(Double(i - 5) / 5 * .pi / 2)
            let wobble = reduceMotion ? 0 : 0.12 * sin(phase * 7 + Double(i) * 0.9)
            return 3 + 17 * CGFloat(max(0, Double(model.level) * weight + wobble * Double(model.level) + 0.04))
        case .initializing:
            return 3 + (reduceMotion ? 0 : 2 * CGFloat(1 + sin(phase * 3)))
        default:
            return 3
        }
    }

    private func barOpacity(_ i: Int, phase: Double) -> Double {
        guard model.state == .transcribing, !reduceMotion else { return 1 }
        // A highlight sweeping across the row until text arrives.
        let position = (phase * 1.2).truncatingRemainder(dividingBy: 1) * 14 - 1.5
        return 0.35 + 0.65 * max(0, 1 - abs(Double(i) - position) / 2.5)
    }
}

/// The current toast: a card on the screen side of the bar.
struct PopupView: View {
    let model: BarModel

    private var alignment: Alignment {
        switch model.anchor {
        case .left: .leading
        case .right: .trailing
        case .top, .topLeft, .topRight: .top
        default: .bottom
        }
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if let toast = model.toast {
                card(toast)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(8)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button { model.dismissToast() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if toast.keycap != nil || !toast.actions.isEmpty {
                HStack(spacing: 8) {
                    if let keycap = toast.keycap {
                        Text(keycap).font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                    ForEach(toast.actions.indices, id: \.self) { i in
                        let action = toast.actions[i]
                        Button(action.label) {
                            action.run()
                            model.dismissToast()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
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
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.popupRadius).fill(Tokens.barGlass))
        .overlay(RoundedRectangle(cornerRadius: Tokens.popupRadius).strokeBorder(.white.opacity(0.1)))
        .onHover { model.toastPaused = $0 }
        .accessibilityElement(children: .contain)
    }
}
