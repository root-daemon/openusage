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
        ]

        for context in contexts {
            XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(context))
        }
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
