import XCTest
@testable import OpenUsage

final class PanelOutsideClickPolicyTests: XCTestCase {
    func testNormalOutsideClickDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init()))
    }

    func testEveryKeepOpenReasonKeepsPanelOpen() {
        let contexts: [PanelOutsideClickContext] = [
            .init(isMorphing: true),
            .init(hasAttachedSheet: true),
            .init(isOnStatusButton: true),
            .init(isPanelWindow: true),
            .init(isStatusItemWindow: true),
            .init(eventWindowTypeName: "NSMenuWindow"),
            .init(eventWindowTypeName: "_NSPopoverWindow"),
        ]

        for context in contexts {
            XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(context))
        }
    }

    func testPopoverWindowMatchIsCaseInsensitive() {
        // A click inside a hover popover (its own `_NSPopoverWindow`, floating outside the panel frame)
        // must keep the panel open so interactive controls in it — the resets "Use" button — receive
        // the click instead of being dismissed as an outside click.
        XCTAssertTrue(
            PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "myPOPOVERwindow"))
        )
    }

    func testInsidePanelKeepsOpenWithoutAnEventWindow() {
        XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(isInsidePanel: true)))
    }

    func testInsidePanelStillKeepsOpenWhenAnotherReasonAlsoApplies() {
        XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(isMorphing: true, isInsidePanel: true)))
    }

    func testMenuWindowMatchIsCaseInsensitive() {
        XCTAssertTrue(
            PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "privateMENUwindow"))
        )
    }

    func testUnrelatedWindowDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "NSWindow")))
    }
}
