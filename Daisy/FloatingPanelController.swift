//
//  FloatingPanelController.swift
//  Daisy
//
//  Manages the borderless NSPanel that hosts the Daisy widget. The panel
//  floats above all apps, doesn't steal focus, is draggable, and is
//  shown automatically while the session is busy (recording, preparing,
//  summarizing) and tucked away otherwise.
//

import AppKit
import SwiftUI
import Observation

@MainActor
final class FloatingPanelController {
    private let session: RecordingSession
    private var panel: NSPanel?
    private var hasPositionedOnce = false
    /// When set, the panel stays hidden until this date — regardless of
    /// session status. Set by the right-click "Hide for…" menu.
    private var suspendedUntil: Date?

    init(session: RecordingSession) {
        self.session = session
        startObserving()
        // Re-anchor if the user changes display layout.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureOnScreen()
            }
        }
    }

    // MARK: - Lifecycle

    func show() {
        // Honour a user-set suspension — if we're still inside the
        // hide window, don't show even if the session goes busy.
        if let until = suspendedUntil, until > Date() {
            return
        } else if suspendedUntil != nil {
            suspendedUntil = nil  // expired, clear it
        }
        if panel == nil { buildPanel() }
        positionIfNeeded()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Hide the widget for `duration` seconds. Called from the widget's
    /// right-click menu. After the timer fires, visibility is re-derived
    /// from the current session status.
    func hideFor(_ duration: TimeInterval) {
        suspendedUntil = Date().addingTimeInterval(duration)
        hide()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self else { return }
            // The user may have changed their mind via "Show now" elsewhere;
            // only re-apply if the suspension we set is still active.
            if let until = self.suspendedUntil, until <= Date() {
                self.suspendedUntil = nil
                self.applyVisibility(for: self.session.status)
            }
        }
    }

    // MARK: - Status observation

    /// Registers a one-shot observation callback that re-fires whenever
    /// `session.status` changes, so visibility tracks the model without
    /// polling.
    private func startObserving() {
        applyVisibility(for: session.status)
        withObservationTracking {
            _ = session.status
        } onChange: {
            // Hop back to main and re-arm.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyVisibility(for: self.session.status)
                self.startObserving()
            }
        }
    }

    private func applyVisibility(for status: RecordingSession.Status) {
        switch status {
        case .recording, .summarizing, .preparing, .stopping, .finished, .failed:
            // Daisy stays on screen through the whole arc — including
            // the brief `.stopping` transition (was causing a flicker
            // when going stopping → summarizing) and after the session
            // ends, until the user explicitly starts a new one or hides
            // it via the right-click menu.
            show()
        case .idle:
            hide()
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let widget = DaisyWidget(
            session: session,
            onHideRequest: { [weak self] duration in
                self?.hideFor(duration)
            }
        )
        // Container is bigger than the daisy itself so the SwiftUI
        // drop-shadow has room to breathe — otherwise the panel's
        // content rect clips it into a hard rectangle.
        let container = ZStack {
            widget
        }
        .frame(width: 80, height: 80)
        let hosting = NSHostingController(rootView: container)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = CGColor.clear

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Don't let AppKit draw its own rectangular window shadow — it
        // produces a visible rectangular halo around the round widget.
        // SwiftUI draws a tighter shadow that hugs the circle.
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = CGColor.clear

        self.panel = panel
    }

    /// Auto-position only on the very first show. After that, the user's
    /// manual drag wins — we never override their placement (except when
    /// the panel has fallen off all displays; see `ensureOnScreen`).
    private func positionIfNeeded() {
        guard let panel = panel, let screen = bestScreen() else { return }
        guard !hasPositionedOnce else {
            ensureOnScreen()
            return
        }
        hasPositionedOnce = true
        anchorBottomRight(panel: panel, on: screen)
    }

    private func ensureOnScreen() {
        guard let panel = panel else { return }
        let frame = panel.frame
        // If any visible screen still contains the centre of the panel,
        // we're fine. Otherwise recover to the bottom-right of the best
        // available screen.
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        let onAnyScreen = NSScreen.screens.contains { $0.frame.contains(centre) }
        if !onAnyScreen, let screen = bestScreen() {
            anchorBottomRight(panel: panel, on: screen)
        }
    }

    /// Prefer the screen the cursor is on (matches user attention), then
    /// fall back to the system's `main` screen, then to whatever's first
    /// in the connected-displays list. Important on multi-display
    /// setups where `NSScreen.main` for a borderless non-key panel can
    /// silently return a different display than the user is using.
    private func bestScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let underCursor = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underCursor
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Anchor at the bottom-right of the screen's visible frame —
    /// roughly Dock level. 80-pt margin sits comfortably in the
    /// corner without crowding the Dock or hugging the screen edge.
    /// Defensive clamp keeps it inside `visibleFrame` regardless of
    /// display scaling or notch.
    private func anchorBottomRight(panel: NSPanel, on screen: NSScreen) {
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 80

        let rawX = frame.maxX - size.width - margin
        let minX = frame.minX + margin
        let maxX = frame.maxX - size.width - 4   // tiny inner gutter
        let x = min(max(minX, rawX), maxX)

        let rawY = frame.minY + margin
        let maxY = frame.maxY - size.height - 4
        let y = min(max(frame.minY, rawY), maxY)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
