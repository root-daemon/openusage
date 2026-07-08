import AppKit
import Observation

/// Owns the menu-bar strip's render loop, split out of `StatusItemController`: render the pinned-metrics
/// strip and re-render whenever anything it reads changes (pins, live data, meter style, menu-bar style).
///
/// `withObservationTracking`'s `onChange` is one-shot, so each render re-arms it. Re-arms are debounced
/// so a refresh-storm burst of snapshot writes collapses into ~one render — the feedback loop that could
/// otherwise starve the MainActor and drop the status item (the "menu bar disappears" failure mode).
@MainActor
final class StatusItemImageUpdater {
    private let container: AppContainer
    private let apply: (NSImage) -> Void
    /// Coalesces re-render requests: a burst of snapshot writes must produce ~one re-render, not
    /// O(writes) MainActor Task hops + ImageRenderer passes. `nil` when idle.
    private var pendingRenderTask: Task<Void, Never>?

    /// - Parameter apply: sets the rendered image onto the status-item button.
    init(container: AppContainer, apply: @escaping (NSImage) -> Void) {
        self.container = container
        self.apply = apply
    }

    /// Render now and re-arm on the next observable change.
    func update() {
        let image = withObservationTracking {
            renderButtonImage()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
            }
        }
        apply(image)
    }

    /// Debounce the re-render so a burst settles into one render instead of one render per write.
    private func schedule() {
        pendingRenderTask?.cancel()
        pendingRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// The pinned-metrics strip in the chosen style, or the app icon when nothing is pinned.
    private func renderButtonImage() -> NSImage {
        let content = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) }
        )
        return MenuBarStripRenderer.image(for: content, style: container.layout.menuBarStyle)
            ?? MenuBarIcon.image
            ?? MenuBarStripRenderer.fallbackIcon
    }
}
