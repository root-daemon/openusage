import XCTest
@testable import OpenUsage

@MainActor
final class CodexAccountStoreTests: XCTestCase {
    func testDefaultAccountExistsWithoutCredentials() {
        let store = CodexAccountStore(defaults: makeDefaults("default"), keychain: ServiceKeychain())

        let contexts = store.accountContexts()

        XCTAssertEqual(contexts.map(\.record.providerID), ["codex"])
        XCTAssertEqual(contexts.map(\.record.displayName), ["Codex"])
        XCTAssertEqual(contexts.map(\.record.source), [.managed])
        XCTAssertEqual(store.visibleRecords(), [])
    }

    func testManagedAccountUsesLegacyCodexProviderIDWhenFirst() throws {
        let keychain = ServiceKeychain()
        let store = CodexAccountStore(defaults: makeDefaults("first"), keychain: keychain)

        try store.saveManagedAuth(auth(accountID: "acct_1", accessToken: "access_1"))

        let records = store.visibleRecords()
        XCTAssertEqual(records.map(\.providerID), ["codex"])
        XCTAssertEqual(records.map(\.displayName), ["Codex"])
        XCTAssertEqual(records.first?.source, .managed)
        XCTAssertEqual(keychain.values.count, 1)
    }

    func testDuplicateManagedLoginRefreshesExistingAccountAndKeepsName() throws {
        let keychain = ServiceKeychain()
        let store = CodexAccountStore(defaults: makeDefaults("duplicate"), keychain: keychain)

        try store.saveManagedAuth(auth(accountID: "acct_1", accessToken: "old"))
        store.rename("acct_1", displayName: "Work")
        try store.saveManagedAuth(auth(accountID: "acct_1", accessToken: "new"))

        XCTAssertEqual(store.visibleRecords().map(\.displayName), ["Work"])
        XCTAssertEqual(store.visibleRecords().count, 1)
        XCTAssertEqual(keychain.values.count, 1)
    }

    func testCLIAccountIsNotImported() {
        let files = FakeFiles([
            "/tmp/codex/auth.json": #"{"tokens":{"access_token":"cli_access","refresh_token":"cli_refresh"}}"#
        ])
        let env = FakeEnvironment(["CODEX_HOME": "/tmp/codex"])
        let store = CodexAccountStore(defaults: makeDefaults("cli"), environment: env, files: files, keychain: ServiceKeychain())

        XCTAssertEqual(store.visibleRecords(), [])
        XCTAssertEqual(store.accountContexts().map(\.record.providerID), ["codex"])
    }

    func testExtraAccountGetsStablePrefixedProviderID() throws {
        let store = CodexAccountStore(defaults: makeDefaults("multi"), keychain: ServiceKeychain())

        try store.saveManagedAuth(auth(accountID: "acct_1", accessToken: "access_1"))
        try store.saveManagedAuth(auth(accountID: "acct_2", accessToken: "access_2"))

        let records = store.visibleRecords()
        XCTAssertEqual(records.first?.providerID, "codex")
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[1].providerID.hasPrefix("codex."))
        XCTAssertEqual(records.map(\.displayName), ["Codex", "Codex 2"])
    }

    private func auth(accountID: String, accessToken: String) -> CodexAuth {
        CodexAuth(
            tokens: CodexTokens(
                accessToken: accessToken,
                refreshToken: "refresh_\(accountID)",
                idToken: nil,
                accountID: accountID
            ),
            lastRefresh: "2026-01-01T00:00:00Z",
            apiKey: nil
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageTests.CodexAccountStore.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
