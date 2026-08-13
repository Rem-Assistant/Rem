import Foundation
import Testing
@testable import RemClaw

/// Covers the pure overflow/threshold logic behind `BoundedToolResultScroll`'s
/// max-height + internal-scroll cap on long expanded tool-result bodies.
struct ScrollEdgeFadeStateTests {
    private let cap: CGFloat = 320

    @Test func shortResultShowsNoFadesAndDoesNotEngageCap() {
        // A short body content-sizes below the cap → no overflow → no fades.
        let state = ScrollEdgeFadeState.from(contentHeight: 120, containerHeight: 120, offsetY: 0)
        #expect(state.showsTop == false)
        #expect(state.showsBottom == false)
    }

    @Test func bodyExactlyFillingCapDoesNotFade() {
        // Content equal to the container (within slack) must not flicker a fade.
        let state = ScrollEdgeFadeState.from(contentHeight: cap, containerHeight: cap, offsetY: 0)
        #expect(state.showsTop == false)
        #expect(state.showsBottom == false)
    }

    @Test func longResultAtTopShowsBottomFadeOnly() {
        // A long result scrolled to the top: more below, nothing hidden above.
        let state = ScrollEdgeFadeState.from(contentHeight: 900, containerHeight: cap, offsetY: 0)
        #expect(state.showsTop == false)
        #expect(state.showsBottom == true)
    }

    @Test func longResultScrolledMiddleShowsBothFades() {
        let state = ScrollEdgeFadeState.from(contentHeight: 900, containerHeight: cap, offsetY: 200)
        #expect(state.showsTop == true)
        #expect(state.showsBottom == true)
    }

    @Test func longResultScrolledToBottomShowsTopFadeOnly() {
        // offsetY at max: visibleMaxY == contentHeight → nothing more below.
        let state = ScrollEdgeFadeState.from(contentHeight: 900, containerHeight: cap, offsetY: 900 - cap)
        #expect(state.showsTop == true)
        #expect(state.showsBottom == false)
    }
}
