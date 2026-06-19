import AppKit
import SwiftUI

/// A hover tooltip that behaves like the native `.help()` tooltip but appears after a delay we control
/// (the native one waits ~1.5-2s on the first hover, with no public API to shorten) and is placed
/// above the cursor, centered on it.
///
/// It's drawn in its own borderless, non-activating, click-through `NSPanel` — not a SwiftUI overlay.
/// A SwiftUI overlay lives inside the popover's window and is clipped to it (and to the dashboard's
/// scroll view), so it can't float freely the way a tooltip must. The panel sits at `.popUpMenu` level
/// (above the status-item popover), never becomes key and never activates the app (shown via
/// `orderFrontRegardless()`), which is the documented carve-out that keeps it from dismissing the
/// transient popover; `ignoresMouseEvents` makes it click-through so it can't steal the hover that
/// spawned it.
///
/// Usage: `.hoverTooltip(_:)` on any hover target. No root container is needed — the panel is a
/// separate window owned by `TooltipPresenter`.

extension View {
    /// Shows `text` in a hover tooltip after a short delay, positioned above the cursor. `nil` or empty
    /// shows nothing, so the many `someTooltip ?? ""` call sites keep their "no tooltip when blank"
    /// behavior. The text is also exposed as an accessibility hint — the part `.help()` gave VoiceOver.
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

/// Per-target nesting depth so a nested control's tooltip beats its container's when a hover sits in
/// both (e.g. the clear button inside the Settings shortcut field). Each target bumps it for its
/// descendants; `TooltipPresenter` shows the deepest active one.
private struct TooltipDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private extension EnvironmentValues {
    var tooltipDepth: Int {
        get { self[TooltipDepthKey.self] }
        set { self[TooltipDepthKey.self] = newValue }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String?
    @Environment(\.tooltipDepth) private var depth
    @Environment(\.reduceTransparencyEffective) private var reduceTransparency
    /// Stable per-target identity, so the presenter can track which targets are currently hovered and
    /// drop this one on exit.
    @State private var id = UUID()

    /// `nil` (no tooltip) for a missing or blank string, collapsing the two "absent" cases.
    private var resolved: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    func body(content: Content) -> some View {
        content
            // Descendants nest one level deeper, so a child target outranks this one when a hover sits
            // inside both.
            .environment(\.tooltipDepth, depth + 1)
            .accessibilityHint(resolved ?? "")
            // Continuous (not plain `onHover`) so the presenter always has the live hover state; it
            // reads the cursor itself at show time, so the reported location is unused here.
            .onContinuousHover { phase in
                guard let resolved else { return }
                switch phase {
                case .active:
                    TooltipPresenter.shared.enter(id: id, text: resolved, depth: depth,
                                                  reduceTransparency: reduceTransparency)
                case .ended:
                    TooltipPresenter.shared.exit(id: id)
                }
            }
            // A row can be torn down (scroll, screen switch, popover close) without an `.ended`, so
            // clear our entry here too or the panel could linger.
            .onDisappear { TooltipPresenter.shared.exit(id: id) }
    }
}

/// Owns the single reused tooltip panel and decides which hovered target is shown. Main-actor isolated:
/// every entry point is a SwiftUI hover callback (already on the main actor) and it only touches AppKit.
@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private struct Target {
        let text: String
        let depth: Int
        let reduceTransparency: Bool
    }

    /// Targets the cursor is currently inside. More than one only while a hover sits in both a child
    /// and its container; the deepest wins.
    private var active: [UUID: Target] = [:]
    /// The target currently on screen, and the one a pending reveal is scheduled for.
    private var shownID: UUID?
    private var pendingID: UUID?
    private var revealTask: Task<Void, Never>?

    /// Mirrors the native tooltip: a real wait on the first hover, then near-instant reshows for a
    /// short grace window after one was last shown ("quick mode").
    private let initialDelay: Duration = .milliseconds(350)
    private let quickDelay: Duration = .milliseconds(60)
    private let quickWindow: Duration = .milliseconds(1500)
    private let clock = ContinuousClock()
    private var lastHideAt: ContinuousClock.Instant?

    /// Space above the cursor; the panel's bottom edge sits this far above the pointer.
    private let cursorGap: CGFloat = 10

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let panel = NonKeyPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],   // set once at init; toggling later desyncs activation
        backing: .buffered,
        defer: false
    )

    private init() {
        // Configure the panel up front (not lazily) so the hosting view is in a window from the start
        // and `fittingSize` measures correctly on the first show. Default sizing options stay on so the
        // host has an intrinsic size to report; the bubble is `.fixedSize()`, so that equals the size we
        // set and the host can't grow the panel out from under us.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu                          // above the status-item popover (.statusBar)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true                   // click-through; never intercepts the hover
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                            // window shadow follows the bubble's rounded shape
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentView = host
    }

    func enter(id: UUID, text: String, depth: Int, reduceTransparency: Bool) {
        active[id] = Target(text: text, depth: depth, reduceTransparency: reduceTransparency)
        refresh()
    }

    func exit(id: UUID) {
        guard active[id] != nil else { return }
        active[id] = nil
        refresh()
    }

    /// Reconcile the panel with the deepest active target. Cheap and idempotent, so the per-pixel
    /// `onContinuousHover` calls mostly hit an early return.
    private func refresh() {
        guard let top = active.max(by: { $0.value.depth < $1.value.depth }) else {
            cancelPending()
            hide()
            return
        }
        if shownID == top.key { return }            // already showing the right one — don't reposition
        if shownID != nil {                         // a tooltip is up for another target — switch now
            present(top.value)
            shownID = top.key
            cancelPending()
            return
        }
        if pendingID == top.key { return }          // already scheduled for this target
        cancelPending()
        pendingID = top.key
        let target = top.value
        let id = top.key
        let delay = isInQuickMode ? quickDelay : initialDelay
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.present(target)
            self.shownID = id
            self.pendingID = nil
            self.revealTask = nil
        }
    }

    private var isInQuickMode: Bool {
        guard let lastHideAt else { return false }
        return clock.now - lastHideAt < quickWindow
    }

    private func cancelPending() {
        revealTask?.cancel()
        revealTask = nil
        pendingID = nil
    }

    private func hide() {
        if shownID != nil { lastHideAt = clock.now }   // open the quick-mode window only after a real show
        shownID = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func present(_ target: Target) {
        host.rootView = AnyView(TooltipBubble(text: target.text, reduceTransparency: target.reduceTransparency))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, cursor: NSEvent.mouseLocation))
        panel.orderFrontRegardless()                   // show without activating the app or taking key
    }

    /// Above the cursor and centered on it, clamped to the cursor's screen; flips below the cursor when
    /// it would clip the top. All math in Cocoa screen coordinates (bottom-left origin, y grows up),
    /// matching `NSEvent.mouseLocation` and `NSScreen.visibleFrame`.
    private func origin(for size: CGSize, cursor: NSPoint) -> NSPoint {
        var x = cursor.x - size.width / 2
        var y = cursor.y + cursorGap
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX), visible.maxX - size.width)
            if y + size.height > visible.maxY {
                y = cursor.y - cursorGap - size.height
            }
            y = max(y, visible.minY)
        }
        return NSPoint(x: x, y: y)
    }

}

/// Never becomes key or main, so showing it can't pull focus and dismiss the transient popover.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bubble drawn inside the panel: a frosted material on glass, a solid fill under Reduce
/// Transparency, with a hairline border. Sizes to its content (`fittingSize` drives the panel size);
/// the panel's window shadow supplies the drop shadow.
private struct TooltipBubble: View {
    let text: String
    let reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
    }
}
