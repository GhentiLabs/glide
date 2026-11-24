import CoreGraphics
import Testing
@testable import Overlay

@Suite struct BarAnchorTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func dropsSnapToTheNearestSpot() {
        #expect(BarAnchor.nearest(to: CGPoint(x: 760, y: 40), in: screen) == .bottom)
        #expect(BarAnchor.nearest(to: CGPoint(x: 30, y: 20), in: screen) == .bottomLeft)
        #expect(BarAnchor.nearest(to: CGPoint(x: 1500, y: 500), in: screen) == .right)
        #expect(BarAnchor.nearest(to: CGPoint(x: 10, y: 470), in: screen) == .left)
        #expect(BarAnchor.nearest(to: CGPoint(x: 1490, y: 970), in: screen) == .topRight)
    }

    @Test func secondScreenUsesItsOwnFrame() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(BarAnchor.nearest(to: CGPoint(x: 1520, y: 540), in: external) == .left)
    }
}
