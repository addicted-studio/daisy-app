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
    private let settings: AppSettings
    private var panel: NSPanel?
    /// Secondary panel anchored above the daisy that hosts the
    /// "Are we done?" bubble. Built lazily; lives only while
    /// `session.silenceMonitor.questionVisible == true`.
    private var bubblePanel: NSPanel?
    private var hasPositionedOnce = false
    /// When set, the panel stays hidden until this date — regardless of
    /// session status. Set by the right-click "Hide for…" menu.
    private var suspendedUntil: Date?

    init(session: RecordingSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        startObserving()
        startObservingSettings()
        startObservingSilence()
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

    /// Parallel observation hook for `settings.floatingWidgetEnabled`.
    /// Re-applies visibility immediately so toggling the master
    /// switch in Settings shows/hides the panel without needing a
    /// session-status change to retrigger.
    private func startObservingSettings() {
        withObservationTracking {
            _ = settings.floatingWidgetEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyVisibility(for: self.session.status)
                self.startObservingSettings()
            }
        }
    }

    private func applyVisibility(for status: RecordingSession.Status) {
        // Master switch: the floating widget is opt-in (Settings →
        // Capture → "Show floating widget"). When OFF, the panel
        // never appears regardless of session state.
        guard settings.floatingWidgetEnabled else {
            hide()
            return
        }
        switch status {
        case .recording, .paused, .summarizing, .preparing, .stopping, .finished, .failed:
            // Daisy stays on screen through the whole arc — including
            // the brief `.stopping` transition (was causing a flicker
            // when going stopping → summarizing) and after the session
            // ends, until the user explicitly starts a new one or hides
            // it via the right-click menu. `.paused` keeps the widget
            // visible so the user can tap to resume.
            show()
        case .idle:
            hide()
        }
    }

    /// Re-evaluate visibility against the current session state.
    /// Called by MainView when `settings.floatingWidgetEnabled`
    /// flips, so the widget appears/disappears the moment the
    /// toggle changes without needing a status change to retrigger.
    func reevaluateVisibility() {
        applyVisibility(for: session.status)
    }

    // MARK: - Silence bubble

    /// Watches `session.silenceMonitor.questionVisible` and shows /
    /// hides the bubble panel accordingly. Self-rearming, same shape
    /// as `startObserving()`.
    private func startObservingSilence() {
        applyBubbleVisibility()
        withObservationTracking {
            _ = session.silenceMonitor.questionVisible
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyBubbleVisibility()
                self.startObservingSilence()
            }
        }
    }

    private func applyBubbleVisibility() {
        // Allow the bubble during .paused too — the long-pause case
        // is exactly when the user has most likely forgotten about
        // a session quietly draining battery. Filtering on
        // `.recording` alone (the v1.0 condition) hid the prompt
        // for the more common failure mode.
        let isActiveSession = session.status == .recording
            || session.status == .paused
        let shouldShow = settings.floatingWidgetEnabled
            && session.silenceMonitor.questionVisible
            && isActiveSession
        if shouldShow {
            showBubble()
        } else {
            hideBubble()
        }
    }

    private func showBubble() {
        if bubblePanel == nil { buildBubblePanel() }
        positionBubble()
        bubblePanel?.orderFrontRegardless()
    }

    private func hideBubble() {
        bubblePanel?.orderOut(nil)
    }

    private func buildBubblePanel() {
        let bubble = SilenceBubble(
            onConfirm: { [weak self] in
                guard let self else { return }
                self.session.silenceMonitor.acknowledge()
                Task { await self.session.stop() }
            },
            onDismiss: { [weak self] in
                self?.session.silenceMonitor.snooze()
            }
        )
        let hosting = NSHostingController(rootView: bubble)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = CGColor.clear

        // Initial size is a sensible default; the bubble's SwiftUI
        // body actually sets `.frame(width: 220)` and lets vertical
        // be intrinsic, so `setContentSize` after host layout will
        // reshape this to the real measurement. Starting at 220×90
        // means the first paint isn't grossly oversized.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 90),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Let SwiftUI's shadow do the work — AppKit's window shadow
        // adds a rectangular halo that doesn't follow the rounded
        // corners (same reason the daisy widget panel turns it off).
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = CGColor.clear
        // Make the bubble accept clicks without stealing focus from
        // whatever the user was just doing.
        panel.becomesKeyOnlyIfNeeded = true
        // Ask the hosting controller for its preferred size and resize
        // the panel to match — otherwise the panel keeps the 240×100
        // bootstrap rect and our positioning maths uses the wrong
        // height when computing the "above the widget" Y.
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        if fitted.width > 0, fitted.height > 0 {
            panel.setContentSize(fitted)
        }
        self.bubblePanel = panel
    }

    /// Park the bubble against the daisy panel, preferring above-
    /// centered, with auto-flip below and clamping to the active
    /// screen's visible frame. The naive "centered on widget" placement
    /// pushed the right edge of the bubble off-screen when the widget
    /// was anchored at bottom-right (the default) — bubble half-width
    /// (130 pt) exceeded the widget's margin from the right edge.
    ///
    /// Layout algorithm:
    ///   1. Pick the screen the daisy panel actually sits on (not
    ///      `NSScreen.main` — that can return a different display on
    ///      multi-monitor setups where the user moved the panel).
    ///   2. Prefer placing the bubble ABOVE the widget, horizontally
    ///      centered on it.
    ///   3. Clamp the X so the bubble is fully inside the visible
    ///      frame with an 8 pt inner gutter.
    ///   4. If the bubble would clip the top of the screen, flip
    ///      below the widget instead.
    ///   5. If it would clip the bottom too (tiny screen), pin to
    ///      the top of the visible frame.
    private func positionBubble() {
        guard let bubblePanel else { return }
        let bubbleSize = bubblePanel.frame.size
        let anchor: NSRect = panel?.frame ?? defaultBubbleAnchor()
        let screen = screenContaining(rect: anchor) ?? bestScreen() ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            // Last-ditch: drop it where the old code would have, but
            // at least keep the right edge off-screen.
            bubblePanel.setFrameOrigin(NSPoint(x: anchor.midX - bubbleSize.width / 2,
                                               y: anchor.maxY + 8))
            return
        }

        let gutter: CGFloat = 8
        let gap: CGFloat = 10

        // Horizontal: center on widget, clamp into [minX, maxX].
        let preferredX = anchor.midX - bubbleSize.width / 2
        let minX = visible.minX + gutter
        let maxX = visible.maxX - bubbleSize.width - gutter
        let x = min(max(preferredX, minX), maxX)

        // Vertical: prefer above. macOS coordinate space has Y going up,
        // so "above the widget" = bigger Y.
        let preferredY = anchor.maxY + gap
        let yIfAbove = preferredY
        let yIfBelow = anchor.minY - bubbleSize.height - gap

        let topClamp = visible.maxY - bubbleSize.height - gutter
        let bottomClamp = visible.minY + gutter

        let y: CGFloat
        if yIfAbove <= topClamp {
            // Fits above — use it.
            y = yIfAbove
        } else if yIfBelow >= bottomClamp {
            // Doesn't fit above; flip below.
            y = yIfBelow
        } else {
            // Doesn't fit either way (very tiny screen / unusual
            // dock layout). Pin to the top of the visible frame.
            y = topClamp
        }

        bubblePanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Find the screen whose `frame` contains the centre of `rect`.
    /// Used to position the bubble on the same display as the daisy
    /// panel — on multi-monitor setups `NSScreen.main` and the panel's
    /// actual screen routinely diverge for borderless non-key panels.
    private func screenContaining(rect: NSRect) -> NSScreen? {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(centre) })
    }

    private func defaultBubbleAnchor() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 80, height: 80)
        }
        let visible = screen.visibleFrame
        return NSRect(x: visible.maxX - 120, y: visible.maxY - 160, width: 80, height: 80)
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
