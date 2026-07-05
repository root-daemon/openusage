import CryptoKit
import Foundation
import Observation

struct CodexAccountRecord: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        case managed
        case cliFile
        case cliKeychain
    }

    var id: String { identity }
    var identity: String
    var providerID: String
    var displayName: String
    var source: Source
    var keychainService: String?
}

struct CodexAccountContext: Sendable {
    var record: CodexAccountRecord
    var authStore: CodexAuthStore
    var logUsageScanner: CodexLogUsageScanner
}

@MainActor
@Observable
final class CodexAccountStore {
    private static let defaultsKey = "openusage.codex.accounts.v1"
    private static let keychainServicePrefix = "OpenUsage Codex Account"
    private static let placeholderIdentity = "placeholder"

    private let defaults: UserDefaults
    private let environment: EnvironmentReading
    private let files: TextFileAccessing
    private let keychain: KeychainAccessing
    private let homeDirectory: @Sendable () -> URL

    private(set) var managedAccounts: [CodexAccountRecord]
    var lastError: String?

    init(
        defaults: UserDefaults = .standard,
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.defaults = defaults
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        let saved = Self.decodeAccounts(from: defaults, key: Self.defaultsKey)
        self.managedAccounts = Self.assignProviderIDs(saved.filter { $0.source == .managed })
    }

    func accountContexts() -> [CodexAccountContext] {
        let records = visibleRecords()
        if records.isEmpty {
            let record = CodexAccountRecord(
                identity: Self.placeholderIdentity,
                providerID: "codex",
                displayName: "Codex",
                source: .managed,
                keychainService: managedService(identity: Self.placeholderIdentity)
            )
            return [context(for: record)]
        }
        return records.map(context(for:))
    }

    func visibleRecords() -> [CodexAccountRecord] {
        Self.assignProviderIDs(managedAccounts.filter { $0.source == .managed })
    }

    func settingsRecords() -> [CodexAccountRecord] {
        visibleRecords()
    }

    func saveManagedAuth(_ auth: CodexAuth) throws {
        let identity = Self.identity(for: auth)
        let service = managedService(identity: identity)
        let encoder = JSONEncoder()
        let data = try encoder.encode(auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }
        try keychain.writeGenericPassword(service: service, value: text)

        var next = managedAccounts
        if let index = next.firstIndex(where: { $0.identity == identity }) {
            next[index].keychainService = service
            next[index].source = .managed
        } else {
            next.append(CodexAccountRecord(
                identity: identity,
                providerID: "codex",
                displayName: defaultDisplayName(position: next.count),
                source: .managed,
                keychainService: service
            ))
        }
        managedAccounts = Self.assignProviderIDs(next)
        persist()
        lastError = nil
    }

    func rename(_ identity: String, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = managedAccounts.firstIndex(where: { $0.identity == identity })
        else { return }
        managedAccounts[index].displayName = trimmed
        managedAccounts = Self.assignProviderIDs(managedAccounts)
        persist()
        lastError = nil
    }

    func removeManaged(_ identity: String) {
        guard let index = managedAccounts.firstIndex(where: { $0.identity == identity }) else { return }
        let removed = managedAccounts.remove(at: index)
        if let service = removed.keychainService {
            do {
                try keychain.deleteGenericPassword(service: service)
            } catch {
                AppLog.warn(LogTag.auth("codex"), "failed to delete removed Codex account credentials: \(error.localizedDescription)")
            }
        }
        managedAccounts = Self.assignProviderIDs(managedAccounts)
        persist()
    }

    private func context(for record: CodexAccountRecord) -> CodexAccountContext {
        CodexAccountContext(
            record: record,
            authStore: CodexAuthStore(
                environment: environment,
                files: files,
                keychain: keychain,
                authPathsOverride: [],
                keychainService: record.keychainService ?? managedService(identity: record.identity)
            ),
            logUsageScanner: CodexLogUsageScanner(environment: environment, homeDirectory: homeDirectory)
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(managedAccounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func managedService(identity: String) -> String {
        "\(Self.keychainServicePrefix) \(identity)"
    }

    private func defaultDisplayName(position: Int) -> String {
        position == 0 ? "Codex" : "Codex \(position + 1)"
    }

    private static func decodeAccounts(from defaults: UserDefaults, key: String) -> [CodexAccountRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([CodexAccountRecord].self, from: data)
        else { return [] }
        return records
    }

    private static func assignProviderIDs(_ records: [CodexAccountRecord]) -> [CodexAccountRecord] {
        records.enumerated().map { index, record in
            var next = record
            next.providerID = index == 0 ? "codex" : "codex.\(shortHash(record.identity))"
            if next.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next.displayName = index == 0 ? "Codex" : "Codex \(index + 1)"
            }
            return next
        }
    }

    private static func shortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(for auth: CodexAuth) -> String {
        if let accountID = auth.tokens?.accountID?.nilIfEmpty { return accountID }
        if let sub = auth.tokens?.idToken.flatMap({ ProviderParse.jwtPayload($0)?["sub"] as? String })?.nilIfEmpty {
            return sub
        }
        if let sub = auth.tokens?.accessToken.flatMap({ ProviderParse.jwtPayload($0)?["sub"] as? String })?.nilIfEmpty {
            return sub
        }
        if let token = auth.tokens?.accessToken?.nilIfEmpty { return shortHash(token) }
        return UUID().uuidString
    }
}
