import Foundation
import Observation

/// Composition root: owns the registry and the mutable stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    var registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let codexAccounts: CodexAccountStore
    let codexOAuth: CodexOAuthCoordinator
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    var apiKeyProviders: [any APIKeyManaging]
    /// Quota pace notification preferences (three independent triggers). Drives the Settings section
    /// and is read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Anonymous, opt-out usage telemetry (daily rollups). Exposed so Settings can toggle it and the
    /// app-termination hook can flush any queued events.
    let telemetry: TelemetryRecorder
    /// Source of truth for the popover's transparency: the persisted Increase Transparency toggle, the
    /// ephemeral secret-code easter-egg state, and the system accessibility flags it yields to. Read by both
    /// the SwiftUI surface and the AppKit panel (`StatusItemController`).
    let transparency: PopoverTransparencyStore
    /// One-time onboarding state (the first-run Customize hint card). Only ever marked pending by
    /// `FirstRunSeeder` on a fresh install, so existing installs never see the card.
    let onboarding: OnboardingStore
    /// Claims Codex rate-limit reset credits from the resets popover (the app's only provider-API
    /// write). Shares the Codex provider's auth store and usage client; `nil` only if the Codex
    /// provider were ever removed from the registry. Injected into the view tree via
    /// `\.codexResetClaim`.
    let codexResetClaim: CodexResetClaimService?
    /// The provider runtimes, kept so on-demand credential detection (the Customize "Reset All" reseed)
    /// can re-probe `hasLocalCredentials()` the same way first-run seeding does.
    private var providers: [ProviderRuntime]
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>
    /// The fresh-install credential-detection pass (see `FirstRunSeeder`); `nil` on every later launch.
    private let seedTask: Task<Void, Never>?
    /// The new-provider credential-detection pass (see `NewProviderSeeder`); `nil` unless this launch is
    /// the first with a provider the install has never seen.
    private let newProviderTask: Task<Void, Never>?

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(isFreshInstall: Bool = false) {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()

        // Default provider order (see AGENTS.md "## Providers"): the three established providers first —
        // Claude, Codex, Cursor — then every other provider alphabetically by display name. This registry
        // order is the default provider order (`LayoutStore.orderedProviderIDs` falls back to it, and
        // `resetToDefault` seeds it), so the dashboard, Customize sections, and the per-provider reset
        // menu all read this way.
        let codexAccounts = CodexAccountStore()
        let providers = Self.makeProviders(codexAccounts: codexAccounts)
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let layout = LayoutStore(
            registry: registry,
            defaultMetricIDs: Self.defaultMetricIDs(for: providers),
            defaultPinnedMetricIDs: Self.defaultPinnedMetricIDs(for: providers),
            defaultExpandedMetricIDs: Self.defaultExpandedMetricIDs(for: providers),
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings }
        )
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        Self.reconcileBrowserOnlyCodexEnablement(
            hasBrowserCodexAccounts: !codexAccounts.visibleRecords().isEmpty,
            enablement: enablement
        )
        // Fresh installs start minimal: seed the enabled-provider list (Claude/Codex/Cursor right away,
        // then the detected set once the local credential probe finishes). No-op on every later launch.
        let onboarding = OnboardingStore()
        self.seedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // Providers added by an update get the same credential detection on their first launch — enabled
        // only when the user actually has the tool. Runs every launch; a no-op unless the registry has a
        // provider this install has never seen (fresh installs were just baselined by FirstRunSeeder).
        self.newProviderTask = NewProviderSeeder.reconcileIfNeeded(
            providers: providers,
            enablement: enablement
        )
        self.providers = providers
        self.onboarding = onboarding
        self.registry = registry
        self.codexAccounts = codexAccounts
        self.codexOAuth = CodexOAuthCoordinator(accountStore: codexAccounts)
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore

        // The resets popover's claim service, sharing the Codex provider's credential loading and HTTP
        // client so the claim's auth can't drift from the provider's. A successful claim forces a Codex
        // refresh so the meters and credit count reconcile before the popover shows its result. The
        // forced refresh returns `.skipped` when another refresh already owns the provider — and that
        // in-flight probe may carry *pre-claim* usage — so retry until this refresh actually runs
        // (bounded; the racing probe finishes in seconds).
        self.codexResetClaim = providers.compactMap { $0 as? CodexProvider }.first.map { codex in
            CodexResetClaimService(
                authStore: codex.authStore,
                usageClient: codex.usageClient,
                refreshAfterClaim: { [weak dataStore] in
                    // The bound must outlast the provider's slowest refresh: usage fetch (10s timeout)
                    // + token refresh (15s) + usage retry (10s) + reset-credit fetch (10s) ≈ 45s. The
                    // common race (the periodic timer's probe) clears in a couple of seconds; the
                    // pathological one keeps the popover's honest "Resetting…" up rather than showing
                    // a success banner over pre-claim meters. A `.failed` probe is retried a few times
                    // too — a transient flake right after the claim must not strand pre-claim meters
                    // behind a success banner — before giving up loudly (the provider error already
                    // shows on the card, so the staleness isn't silent).
                    var failures = 0
                    for attempt in 0..<45 {
                        guard let dataStore else { return }
                        switch await dataStore.refresh(providerID: codex.provider.id, force: true) {
                        case .refreshed, .cacheHit, .backedOff:
                            return
                        case .failed:
                            failures += 1
                            guard failures < 3 else {
                                AppLog.error(LogTag.plugin("codex"), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                                return
                            }
                            try? await Task.sleep(for: .seconds(2))
                        case .skipped:
                            AppLog.info(LogTag.plugin("codex"), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    AppLog.error(LogTag.plugin("codex"), "post-claim refresh kept being skipped; meters may lag until the next cycle")
                }
            )
        }

        // Anonymous, opt-out usage telemetry (two daily-rollup events). Its state lives in a dedicated
        // UserDefaults suite, kept separate from app settings so the user's opt-out choice and the
        // install id stay independent of any settings change. The snapshot closure reads the live
        // layout/enablement so `app_daily_active` always reflects the current configuration.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [registry, enablement, layout] in
                // Report the *active* configuration: a metric whose provider is turned off is hidden
                // from the dashboard and menu bar, so exclude it here too — keeping the metric arrays
                // consistent with `enabledProviders` (which is also enablement-filtered).
                let providerOn: (String) -> Bool = { metricID in
                    guard let providerID = registry.descriptor(id: metricID)?.providerID else { return false }
                    return enablement.isEnabled(providerID)
                }
                return TelemetryConfigSnapshot(
                    enabledProviders: registry.providers.map(\.id).filter { enablement.isEnabled($0) },
                    enabledMetricIDs: layout.placed.map(\.descriptorID).filter(providerOn),
                    pinnedMetricIDs: layout.pinnedMetricIDs.filter(providerOn),
                    expandedMetricIDs: layout.expandedMetricIDs.filter(providerOn),
                    menuBarStyle: layout.menuBarStyle.rawValue
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        self.telemetry = telemetry
        self.transparency = PopoverTransparencyStore()
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.providerOrder.filter { enablement.isEnabled($0) },
                knownIDs: Set(registry.providers.map(\.id)),
                snapshots: dataStore.snapshots
            )
        })
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry)
        localAPI.start()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit {
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    func reloadCodexAccounts() {
        let oldProviderIDs = Set(providers.map(\.provider.id))
        let nextProviders = Self.makeProviders(codexAccounts: codexAccounts)
        let nextRegistry = WidgetRegistry.from(nextProviders)
        let nextProviderIDs = Set(nextProviders.map(\.provider.id))
        let removedProviderIDs = oldProviderIDs.subtracting(nextProviderIDs)
        let addedProviderIDs = nextProviderIDs.subtracting(oldProviderIDs)

        providers = nextProviders
        registry = nextRegistry
        apiKeyProviders = nextProviders.compactMap { $0 as? any APIKeyManaging }
        layout.updateRegistry(
            nextRegistry,
            defaultMetricIDs: Self.codexMetricIDs(for: nextProviders),
            defaultPinnedMetricIDs: Self.codexPinnedMetricIDs(for: nextProviders),
            defaultExpandedMetricIDs: Self.codexExpandedMetricIDs(for: nextProviders)
        )
        dataStore.updateRegistry(nextRegistry, providers: nextProviders, removedProviderIDs: removedProviderIDs)
        enablement.registerKnownProviders(nextProviderIDs)
        for id in addedProviderIDs where id == "codex" || id.hasPrefix("codex.") {
            enablement.setEnabled(true, for: id)
        }
        Self.reconcileBrowserOnlyCodexEnablement(
            hasBrowserCodexAccounts: !codexAccounts.visibleRecords().isEmpty,
            enablement: enablement
        )
    }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore, telemetry: TelemetryRecorder) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await dataStore.refreshAll()
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                // Day-rollover beat: emits `app_daily_active` once per local day and flushes any
                // prior-day provider rollups. Runs on launch and every interval, so always-running
                // instances still produce a daily-active signal.
                telemetry.tick()
                await waitForNextRefresh()
            }
        }
    }

    private static func makeProviders(codexAccounts: CodexAccountStore) -> [ProviderRuntime] {
        [
            ClaudeProvider()
        ] + codexAccounts.accountContexts().map { context in
            CodexProvider(
                providerID: context.record.providerID,
                displayName: context.record.displayName,
                authStore: context.authStore,
                logUsageScanner: context.logUsageScanner
            )
        } + [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(),
            DevinProvider(),
            GrokProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
    }

    private static func defaultMetricIDs(for providers: [ProviderRuntime]) -> [String] {
        DefaultLayout.metricIDs + codexMetricIDs(for: providers).filter { !DefaultLayout.metricIDs.contains($0) }
    }

    private static func defaultPinnedMetricIDs(for providers: [ProviderRuntime]) -> [String] {
        DefaultLayout.pinnedMetricIDs + codexPinnedMetricIDs(for: providers).filter { !DefaultLayout.pinnedMetricIDs.contains($0) }
    }

    private static func defaultExpandedMetricIDs(for providers: [ProviderRuntime]) -> [String] {
        DefaultLayout.expandedMetricIDs + codexExpandedMetricIDs(for: providers).filter { !DefaultLayout.expandedMetricIDs.contains($0) }
    }

    private static func codexMetricIDs(for providers: [ProviderRuntime]) -> [String] {
        providers
            .filter { $0.provider.id == "codex" || $0.provider.id.hasPrefix("codex.") }
            .flatMap { provider in
                [
                    "\(provider.provider.id).session",
                    "\(provider.provider.id).weekly",
                    "\(provider.provider.id).spark",
                    "\(provider.provider.id).sparkWeekly",
                    "\(provider.provider.id).trend",
                    "\(provider.provider.id).credits",
                    "\(provider.provider.id).rateLimitResets",
                    "\(provider.provider.id).today",
                    "\(provider.provider.id).yesterday",
                    "\(provider.provider.id).last30"
                ]
            }
    }

    private static func codexPinnedMetricIDs(for providers: [ProviderRuntime]) -> [String] {
        providers
            .filter { $0.provider.id == "codex" || $0.provider.id.hasPrefix("codex.") }
            .flatMap { ["\($0.provider.id).session", "\($0.provider.id).weekly"] }
    }

    private static func codexExpandedMetricIDs(for providers: [ProviderRuntime]) -> [String] {
        providers
            .filter { $0.provider.id == "codex" || $0.provider.id.hasPrefix("codex.") }
            .flatMap {
                [
                    "\($0.provider.id).spark",
                    "\($0.provider.id).sparkWeekly",
                    "\($0.provider.id).credits",
                    "\($0.provider.id).rateLimitResets",
                    "\($0.provider.id).today",
                    "\($0.provider.id).yesterday",
                    "\($0.provider.id).last30"
                ]
            }
    }

    static func reconcileBrowserOnlyCodexEnablement(hasBrowserCodexAccounts: Bool, enablement: ProviderEnablementStore) {
        guard hasBrowserCodexAccounts,
              enablement.enabledIDs?.contains(where: { $0.hasPrefix("codex.") }) == true,
              !enablement.isEnabled("codex")
        else { return }
        enablement.registerKnownProviders(["codex"])
        enablement.setEnabled(true, for: "codex")
    }

    /// Sleep for the refresh interval, but wake early when the user enables/disables a provider so a
    /// newly-enabled provider is fetched promptly instead of waiting out the full interval. Each pass still
    /// honors the cache (and the per-provider failure backoff), so an early wake only hits the network for
    /// a provider whose snapshot has actually expired.
    ///
    /// Deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the firehose
    /// `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes, Sparkle's
    /// update bookkeeping, and unrelated global-domain changes from other processes. Waking on that, with
    /// no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a refresh storm.
    private static func waitForNextRefresh() async {
        let interval = RefreshSetting.interval
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(interval))
            }
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: ProviderEnablementStore.didChangeNotification) {
                    break
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
