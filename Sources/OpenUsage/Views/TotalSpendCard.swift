import AppKit
import SwiftUI

/// The dashboard's cross-provider Total Spend section: a native segmented period picker
/// (Today / Yesterday / Last 30 Days) over a donut ring whose segments are each provider's share of
/// the period's spend, with the total in the center and a ranked legend beside it. Data comes from
/// `TotalSpendAggregator` over the same snapshots the provider cards render, so the ring always
/// matches the per-provider spend tiles. Shown whenever any enabled provider tracks spend
/// (`LayoutStore.hasSpendCapableProvider`) and the toggle at the top of Settings is on; a period
/// (or a fresh install) with no priced usage shows the "No spend data" state instead of hiding
/// the card.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pickerNamespace

    /// The selected period survives popover closes and relaunches, like the meter-style toggles.
    @AppStorage("openusage.totalSpend.period") private var periodRawValue = TotalSpendPeriod.today.rawValue
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// True briefly after a successful copy: the share arrow becomes a checkmark, then reverts.
    @State private var shareCopied = false
    /// The pending revert, kept so a rapid second click restarts the window instead of cutting the
    /// fresh checkmark short.
    @State private var shareRevertTask: Task<Void, Never>?

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    /// The spend-tile providers the card may aggregate — capability-based (see
    /// `LayoutStore.spendCapableProviders`), so a provider stays counted even when its own rows are
    /// hidden in Customize, and providers with merely similar-looking dollar rows never leak in.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        TotalSpendAggregator.total(for: period, providers: providers, snapshots: dataStore.snapshots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            card
        }
    }

    // MARK: - Header

    /// Section header matching the provider headers' scale: title leading, the share control trailing
    /// where a provider header shows its mark.
    private var header: some View {
        HStack(spacing: 5) {
            Text("Total Spend")
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip)
            Spacer(minLength: 8)
            shareButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    /// Names the providers actually feeding the ring — the enabled spend-capable set — instead of a
    /// hardcoded list, so disabling a provider (or a new spend provider shipping) can't make the
    /// tooltip lie about what the total reflects.
    private var infoTooltip: String {
        let names = providers.map(\.displayName)
        return "Only includes \(names.formatted(.list(type: .and)))."
    }

    private var shareButton: some View {
        Button {
            // The checkmark only appears when the PNG actually landed on the pasteboard — a failed
            // render/copy beeps (inside the renderer) and the icon stays a share arrow.
            guard ShareCardRenderer.shareTotalSpend(total: total, appearance: colorScheme, layout: layout) else { return }
            withAnimation(Motion.spring) { shareCopied = true }
            shareRevertTask?.cancel()
            shareRevertTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.spring) { shareCopied = false }
            }
        } label: {
            ShareFeedbackIcon(copied: shareCopied)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                // Same height as the provider headers' trailing mark, so the header row measures the
                // same and the arrow centers vertically exactly like the provider icons do.
                .frame(width: 16, height: density.headerIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share Total Spend Screenshot")
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 12) {
            periodPicker
            if total.isEmpty {
                emptyState
            } else {
                TotalSpendRingContent(total: total)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .animation(Motion.spring, value: periodRawValue)
        .contextMenu {
            Button("Share Screenshot") {
                ShareCardRenderer.shareTotalSpend(total: total, appearance: colorScheme, layout: layout)
            }
        }
    }

    /// A capsule segmented switcher in the app's own design language (the footer's glass capsule
    /// controls), replacing the stock `.segmented` picker whose legacy rounded-rect chrome clashes
    /// with the Tahoe look. The selected segment is a Liquid Glass capsule (frosted material on
    /// macOS 15) that slides between segments via `matchedGeometryEffect`.
    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TotalSpendPeriod.allCases) { candidate in
                periodSegment(candidate)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func periodSegment(_ candidate: TotalSpendPeriod) -> some View {
        let isSelected = candidate == period
        return Button {
            periodRawValue = candidate.rawValue
        } label: {
            Text(candidate.shortLabel)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .matchedGeometryEffect(id: "totalSpendPeriod", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: periodRawValue)
    }

    /// A period every provider sat out (or one the sources haven't accounted for yet) mirrors the spend
    /// tiles' "No data" rule — never a fabricated $0.00 ring.
    private var emptyState: some View {
        Text("No spend data for this period")
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// The ring + legend body, shared by the live card and the share-card export so the PNG can't drift
/// from what's on screen. Slices come ranked largest-first from the aggregator, so the ring reads
/// clockwise from 12 o'clock in the same order the legend reads top-down.
///
/// A period switch **morphs** the arcs: each provider's slice slides and resizes to its new share.
/// Swift Charts' `SectorMark` can't do this — it matches sectors by array position when animating,
/// so any re-sort smears one provider's arc into another's color mid-morph (there is no identity
/// hook for sectors). The ring therefore draws its own sectors: one `RingSectorShape` per provider,
/// identity-keyed by provider ID, with the start/end angles as `animatableData`. SwiftUI animates
/// each provider's own arc, and the color can't swap because each arc view owns its provider's
/// color. The shape reproduces the SectorMark look — golden-ratio hole, hairline gaps, rounded
/// sector corners — so nothing changes visually at rest.
struct TotalSpendRingContent: View {
    let total: TotalSpend

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private static let ringDiameter: CGFloat = 104

    var body: some View {
        HStack(spacing: 18) {
            ring
            legend
        }
    }

    // MARK: - Ring

    /// Every slice is guaranteed at least this share of the circle, so a $4 provider next to a $20K
    /// one still shows a visible sliver instead of vanishing. Presentation-only — the legend and
    /// center total keep the true dollars.
    private static let minimumSliceShare = 0.025

    private var ring: some View {
        ZStack {
            // Identity is the provider ID: a provider that exists in both periods keeps its view,
            // so a period switch animates that arc's angles. A provider entering or leaving the
            // period fades in/out (the default transition) while the survivors re-flow around it.
            ForEach(arcs) { arc in
                RingSectorShape(startFraction: arc.start, endFraction: arc.end)
                    .fill(TotalSpendPalette.color(for: arc.providerID))
            }
            centerLabel
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Total spend \(MetricFormatter.number(total.totalUSD, kind: .dollars, style: .full)) across \(total.slices.count) providers")
    }

    private struct RingArc: Identifiable, Equatable {
        let providerID: String
        var start: Double
        var end: Double

        var id: String { providerID }
    }

    /// The ranked slices as cumulative ring fractions, with the minimum-sliver floor applied and the
    /// result renormalized so the ring always closes exactly (SectorMark used to normalize for us).
    private var arcs: [RingArc] {
        guard total.totalUSD > 0 else { return [] }
        let floored = total.slices.map { max($0.amountUSD / total.totalUSD, Self.minimumSliceShare) }
        let sum = floored.reduce(0, +)
        guard sum > 0 else { return [] }

        var cursor = 0.0
        return zip(total.slices, floored).map { slice, share in
            let width = share / sum
            defer { cursor += width }
            return RingArc(providerID: slice.provider.id, start: cursor, end: cursor + width)
        }
    }

    /// Just the total, quiet and centered — the legend right next to it already says who and how
    /// many. The tray style keeps it short ("$141", "$13.1K" — never "$140.75"); cents live in the
    /// legend and the hover, which reveals the exact figure (and the local-estimate note when any
    /// contributor is imputed).
    private var centerLabel: some View {
        Text(MetricFormatter.number(total.totalUSD, kind: .dollars, style: .tray))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 14)
            .hoverTooltip(centerTooltip)
    }

    private var centerTooltip: String {
        let exact = MetricFormatter.number(total.totalUSD, kind: .dollars, style: .full)
        return total.isEstimated ? "\(exact) · \(WidgetData.localEstimateNote)" : exact
    }

    // MARK: - Legend

    /// Rows in the ring's ranked order (largest spender first), so scanning the ring clockwise from
    /// 12 o'clock matches reading the legend top-down.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(total.slices) { slice in
                legendRow(slice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendRow(_ slice: TotalSpendSlice) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TotalSpendPalette.color(for: slice.provider.id))
                .frame(width: 8, height: 8)
            Text(slice.provider.displayName)
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Exact to the cent — the compact form already lives in the ring's center.
            Text(MetricFormatter.number(slice.amountUSD, kind: .dollars, style: .full))
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// Stable per-provider brand tints for the Total Spend ring and legend — the one place the app maps
/// a provider to a color, so the chart, legend, and share card always agree. Colors are keyed by
/// provider ID only (never by rank or position), so a provider keeps its color across period
/// switches, re-sorts, and launches. Hexes come from the legacy edition's per-plugin `brandColor`
/// values; brands whose color is plain black (Cursor, Grok) get adaptive near-black/near-white
/// dynamic colors so they read on both appearances without both landing on the same gray.
enum TotalSpendPalette {
    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),                             // Claude terracotta
        "codex": hex(0x10A37F),                              // OpenAI green (#10A37F)
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),  // brand black (#13120A), flipped near-white in dark mode
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),    // brand black, offset to gray next to Cursor
        "openrouter": hex(0x6467F2),                         // OpenRouter indigo
        "antigravity": hex(0x4285F4),                        // Google blue
        "copilot": hex(0xA855F7),                            // Copilot purple
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6)
    ]

    /// Deterministic backstop hues for a provider that ships without a palette entry — keyed off the
    /// provider ID (not rank), so the color holds steady across periods and launches.
    private static let fallback: [Color] = [
        hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)
    ]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A light/dark-adaptive color, for brands whose mark is pure black — invisible on a dark card
    /// unless flipped.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
