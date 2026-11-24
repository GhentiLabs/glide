import AppKit
import GlideCore
import SwiftUI

/// Opens the right System Settings pane and floats a card beside it showing what to switch on.
@MainActor
public final class PermissionGuide {
    public enum Permission: Sendable {
        case accessibility, microphone

        var url: URL {
            switch self {
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            }
        }

        var message: String {
            switch self {
            case .accessibility: "Find Glide under Accessibility and turn it on. If Glide isn't listed, drag this icon into the list."
            case .microphone: "Find Glide under Microphone and turn it on."
            }
        }
    }

    public enum Outcome: Sendable { case granted, settingsClosed, timedOut }

    private static let size = NSSize(width: 300, height: 150)
    private var panel: NSPanel?

    public init() {}

    /// Returns once the permission is granted, Settings is closed, or two minutes pass.
    public func guide(_ permission: Permission, isGranted: @escaping () -> Bool) async -> Outcome {
        NSWorkspace.shared.open(permission.url)
        let panel = makePanel(permission)
        self.panel = panel
        defer {
            panel.orderOut(nil)
            self.panel = nil
        }
        var sawSettings = false
        for _ in 0..<240 {
            if isGranted() { return .granted }
            if let frame = Self.settingsWindowFrame() {
                sawSettings = true
                panel.setFrameOrigin(Self.origin(beside: frame))
                panel.orderFrontRegardless()
            } else if sawSettings {
                return .settingsClosed
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .timedOut
    }

    private func makePanel(_ permission: Permission) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .modalPanel  // above System Settings
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = BarPanel.host(GuideCard(message: permission.message))
        return panel
    }

    /// The Settings window's frame in AppKit coordinates. Window bounds need no permission to read.
    private static func settingsWindowFrame() -> NSRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = windows.first(where: {
            $0[kCGWindowOwnerName as String] as? String == "System Settings" && $0[kCGWindowLayer as String] as? Int == 0
        }),
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds),
            let primary = NSScreen.screens.first
        else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Beside the window on whichever side has room, level with its top.
    private static func origin(beside window: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(window) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? window
        let right = window.maxX + 12
        let x = right + size.width <= bounds.maxX ? right : max(bounds.minX, window.minX - 12 - size.width)
        return NSPoint(x: x, y: min(window.maxY - 80, bounds.maxY) - size.height)
    }
}

private struct GuideCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 52, height: 52)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Drag into the list")
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on Glide").font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Tokens.popupRadius).fill(Tokens.barGlass))
    }
}
