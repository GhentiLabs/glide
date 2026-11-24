import AppKit
import SwiftUI

/// Where the bar sits: one of eight spots on the screen's edge.
public enum BarAnchor: String, CaseIterable, Sendable {
    case bottom, bottomLeft, bottomRight, top, topLeft, topRight, left, right

    var isVertical: Bool { self == .left || self == .right }
    var isCorner: Bool { [.bottomLeft, .bottomRight, .topLeft, .topRight].contains(self) }

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

    /// Corners count as closer than they are, so they catch a drop from further away.
    static func nearest(to point: CGPoint, in frame: CGRect) -> BarAnchor {
        func distance(_ anchor: BarAnchor) -> CGFloat {
            let p = anchor.point(in: frame)
            return hypot(p.x - point.x, p.y - point.y) * (anchor.isCorner ? 0.6 : 1)
        }
        return allCases.min { distance($0) < distance($1) }!
    }

    /// The edge the bar grows out of.
    var edge: Edge {
        switch self {
        case .bottom, .bottomLeft, .bottomRight: .bottom
        case .top, .topLeft, .topRight: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    /// Where the bar sits inside its panel.
    var alignment: Alignment {
        let h: HorizontalAlignment = edges.contains(.leading) ? .leading : edges.contains(.trailing) ? .trailing : .center
        let v: VerticalAlignment = edges.contains(.bottom) ? .bottom : edges.contains(.top) ? .top : .center
        return Alignment(horizontal: h, vertical: v)
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
