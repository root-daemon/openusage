import AppKit

/// Owns the local and global mouse monitors that dismiss the menu-bar panel.
@MainActor
final class PanelOutsideClickMonitor {
    private let panel: MenuBarPanel
    private let statusItem: NSStatusItem
    private let isMorphing: () -> Bool
    private let onInsidePanelClick: () -> Void
    private let onDismiss: () -> Void
    private var monitors: [Any] = []

    init(
        panel: MenuBarPanel,
        statusItem: NSStatusItem,
        isMorphing: @escaping () -> Bool,
        onInsidePanelClick: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.panel = panel
        self.statusItem = statusItem
        self.isMorphing = isMorphing
        self.onInsidePanelClick = onInsidePanelClick
        self.onDismiss = onDismiss
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // NSEvent is not Sendable, so only copy these small values before returning to the main actor.
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            MainActor.assumeIsolated {
                self?.handleClick(
                    windowID: windowID,
                    windowTypeName: windowTypeName,
                    screenPoint: NSEvent.mouseLocation
                )
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Read the location now; the pointer may move before the main-actor task runs.
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(windowID: nil, windowTypeName: nil, screenPoint: screenPoint)
            }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    private func handleClick(
        windowID: ObjectIdentifier?,
        windowTypeName: String?,
        screenPoint: NSPoint
    ) {
        let isInsidePanel = panel.frame.contains(screenPoint)
        let hasWindowContext = windowID != nil && windowTypeName != nil
        let buttonWindowID = statusItem.button?.window.map(ObjectIdentifier.init)
        let context = PanelOutsideClickContext(
            isMorphing: isMorphing(),
            hasAttachedSheet: panel.attachedSheet != nil,
            isOnStatusButton: isOnStatusButton(screenPoint),
            isInsidePanel: isInsidePanel,
            isPanelWindow: hasWindowContext && windowID == ObjectIdentifier(panel),
            isStatusItemWindow: hasWindowContext && windowID == buttonWindowID,
            eventWindowTypeName: hasWindowContext ? windowTypeName : nil
        )

        if PanelOutsideClickPolicy.shouldKeepOpen(context) {
            if isInsidePanel { onInsidePanelClick() }
            return
        }
        onDismiss()
    }

    private func isOnStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else { return false }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonFrame.contains(screenPoint)
    }
}

struct PanelOutsideClickContext {
    var isMorphing = false
    var hasAttachedSheet = false
    var isOnStatusButton = false
    var isInsidePanel = false
    var isPanelWindow = false
    var isStatusItemWindow = false
    var eventWindowTypeName: String?
}

enum PanelOutsideClickPolicy {
    static func shouldKeepOpen(_ context: PanelOutsideClickContext) -> Bool {
        context.isMorphing
            || context.hasAttachedSheet
            || context.isOnStatusButton
            || context.isInsidePanel
            || context.isPanelWindow
            || context.isStatusItemWindow
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("menu") == true
    }
}
