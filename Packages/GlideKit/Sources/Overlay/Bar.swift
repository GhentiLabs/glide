import AppKit
import GlideCore
import SwiftUI

/// What the bar shows. Owned by the app, drawn by `BarPanel`.
@MainActor @Observable
public final class BarModel {
    public var state: SessionState = .idle
    /// Recent microphone levels, oldest first, 0...1.
    public private(set) var levels = [Float](repeating: 0, count: 11)

    public init() {}

    public func push(level rms: Float) {
        // Speech RMS sits around 0.01–0.2; map it onto 0...1 on a log scale.
        let db = 20 * log10(max(rms, 1e-5))
        levels.removeFirst()
        levels.append(min(max((db + 50) / 40, 0), 1))
    }

    public func resetLevels() { levels = [Float](repeating: 0, count: levels.count) }
}

/// The floating bar. shortcut: fixed at bottom centre and click-through; drag, snap positions and Dock awareness arrive in M2.
@MainActor
public final class BarPanel {
    private let panel: NSPanel

    public init(model: BarModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: BarView(model: model).frame(width: 200, height: 48))
    }

    public func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 100, y: frame.minY + 8))
        }
        panel.orderFrontRegardless()
    }
}

struct BarView: View {
    let model: BarModel

    private var expanded: Bool {
        switch model.state {
        case .recording, .transcribing: true
        default: false
        }
    }

    var body: some View {
        content
            .foregroundStyle(.white)
            .frame(width: expanded ? 152 : 56, height: expanded ? 34 : 22)
            .background(Capsule().fill(Tokens.barGlass))
            .overlay {
                if case .error = model.state { Capsule().strokeBorder(.red, lineWidth: 1.5) }
            }
            .animation(Tokens.spring, value: expanded)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .initializing:
            CaretMark(caret: Tokens.tintGraphic).frame(height: 14).opacity(model.state == .initializing ? 0.5 : 1)
        case .recording:
            HStack(spacing: 3) {
                ForEach(model.levels.indices, id: \.self) { i in
                    Capsule().frame(width: 3, height: 4 + 16 * CGFloat(model.levels[i]))
                }
            }
            .animation(.easeOut(duration: Tokens.levelRelease), value: model.levels)
        case .transcribing:
            Capsule().frame(width: 96, height: 2).opacity(0.7)
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
