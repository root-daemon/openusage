# AGENTS.md

OpenUsage is a SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before contributing.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** This is the native Swift edition of OpenUsage. Active development happens on the `main` branch.

## Rollout: Tauri to Swift (read first)

This Swift edition replaces the original Tauri app. Both editions stay in the same GitHub repo and remain independent.
- The `main` branch is the active Swift development line; it ships the Swift edition via `.github/workflows/release.yml` (Sparkle appcast on `gh-pages`).
- The Tauri edition is preserved on `tauri-legacy`. Its final release is `v0.6.28`, which shows the migration banner.

### Guardrails (do not break)
- Version lanes: Swift owns `0.7.x` and up; Tauri stays on `0.6.x`. Never use a `0.6.x` number here.
- Beta Swift releases use `-beta.N` tags and stay GitHub pre-releases on Sparkle's Early Access channel. Stable Swift releases use plain tags, become GitHub "Latest", and must carry forward the final Tauri `latest.json` so older Tauri installs can still update to `v0.6.28`. `release.yml` handles this; verify it with the release-swift skill.
- Never leave a release in Draft, and never ship blank notes: the release-swift skill generates the changelog and verifies the published release after every cut.
- The Tauri edition is frozen and stays in the repo forever. Do not cut another Tauri release unless there is an emergency.

### Phases
(1) private Swift testing via Early Access, (2) final Tauri goodbye release `v0.6.28`, (3) make Swift the default `main` branch and preserve old Tauri as `tauri-legacy`, (4) ship Swift stable releases from `main` with plain tags.

## Architecture

- SwiftPM executable target; SwiftUI content hosted in an AppKit-owned `NSStatusItem` + `NSPopover`.
- Swift 6 with strict concurrency.
- Providers implement the small `ProviderRuntime` protocol: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into `MetricLine` values. The UI renders those normalized values.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

## Running / Testing Changes

- There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a full rebuild and restart of the running app** to take effect — kill the running instance, rebuild, and relaunch before testing.

## Documentation

- Logic changes must update any docs in `docs/` that describe the affected behavior.
- Keep docs simple, less-technical, and easy to skim; exclude visual design details.

## Code Conventions

- Add a regression test when fixing a bug, where it fits.
- Keep files under ~500 LOC; split or refactor as needed.
- No new dependencies without justification.
- Follow the existing per-provider folder structure when adding a provider.

## Adding a Metric

A new metric/widget has four default-placement decisions. These are product calls, not engineering defaults — **confirm each with the user every time before finalizing; never pick them silently.**

- **On or off by default** — enabled on first launch (add the id to `DefaultLayout.metricIDs`) or opt-in only, appearing in the Add Widget gallery (omit it from `metricIDs`).
- **Primary or secondary by default** — shown above the fold (primary), or tucked behind the provider's expand caret (secondary; add the id to `DefaultLayout.expandedMetricIDs`).
- **Pinned or not** — seeded onto the menu-bar strip on first launch (`DefaultLayout.pinnedMetricIDs`), and whether it can be pinned at all (`WidgetDescriptor.pinnable`). A widget with no single scalar value (a chart or list) must be `pinnable: false` and excluded from the tray.
- **Default order** — where it sits among the provider's other metrics. Order is the declaration order in the provider's `widgetDescriptors` array (which seeds both the Customize list and the default layout); there is no separate order list, so place the entry deliberately.

## Error Handling

Always fail loudly into error logging and show friendly errors to the user. Do not add silent fallbacks that hide real problems. Only validate at system boundaries (user input, external APIs); trust internal code and framework guarantees.

## UI

- Use title case for any hardcoded copy used as a title.
- Match the existing design language; OpenUsage has a specific look and feel.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new controls.
