import XCTest
@testable import OpenUsage

@MainActor
final class CodexOAuthCoordinatorTests: XCTestCase {
    func testAuthorizeURLUsesCodexRegisteredLocalhostRedirectURI() throws {
        let redirectURI = CodexOAuthCoordinator.redirectURIForTesting
        let url = CodexOAuthCoordinator.authorizationURLForTesting(
            redirectURI: redirectURI,
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(redirectURI, "http://localhost:1455/auth/callback")
        XCTAssertEqual(query["redirect_uri"], redirectURI)
        XCTAssertNotEqual(query["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
    }
}
