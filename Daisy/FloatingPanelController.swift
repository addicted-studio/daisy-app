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
    private var hasPositionedOnce = false
    /// When set, the panel stays hidden until this date — regardless of
    /// session status. Set by the right-click "Hide for…" menu. Backed by
    /// AppSettings so the suspension is persisted and survives an app
    /// relaunch — it used to be in-memory only, so quitting Daisy dropped
    /// the hide and the widget reappeared well before the chosen window.
    private var suspendedUntil: Date? {
        get { settings.floatingWidgetSuspendedUntil }
        set { settings.floatingWidgetSuspendedUntil = newValue }
    }

    init(session: RecordingSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        startObserving()
        startObservingSettings()
        // Silence-prompt UI used to live here as a custom NSPanel
        // anchored above the daisy widget. Retired 2026-05-18 in
        // favour of a native `UNUserNotification` banner — see
        // `SilencePromptNotification` and `SilenceMonitor`. AppKit
        // handles all positioning / dismissal for free.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureOnScreen()
            }
        }
        // Re-arm a "Hide for…" suspension that was still pending when
        // Daisy last quit. The deadline was restored into AppSettings,
        // so show()'s guard already keeps the widget hidden; here we
        // just schedule the expiry so it reappears at the original time.
        if let until = suspendedUntil {
            if until > Date() {
                rearmSuspensionTimer(until: until)
            } else {
                suspendedUntil = nil
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
        let until = Date().addingTimeInterval(duration)
        suspendedUntil = until
        hide()
        rearmSuspensionTimer(until: until)
    }

    /// Schedule the wake-up that lifts a "Hide for…" suspension when it
    /// expires. Shared by `hideFor` and by launch-time restoration, so a
    /// hide chosen in a previous run still ends at its original deadline
    /// rather than the moment Daisy was relaunched.
    private func rearmSuspensionTimer(until: Date) {
        Task { @MainActor [weak self] in
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard let self else { return }
            // The user may have changed their mind via "Show now"
            // elsewhere, or set a new, later suspension; only lift the
            // one whose deadline has actually passed.
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
        } onChange: { [weak self] in
            // Weak at the OUTER closure — that's the reference the
            // observation registration actually retains. Unwrap here:
            // a weak capture is a mutable box, and Swift 6 forbids the
            // nested Task from capturing a captured `var` — so hand
            // the Task an immutable strong `self` instead (retains
            // the controller only for the duration of the hop).
            guard let self else { return }
            Task { @MainActor in
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
        } onChange: { [weak self] in
            // Weak at the outer closure, unwrapped before the Task —
            // see startObserving() for the rationale.
            guard let self else { return }
            Task { @MainActor in
                self.applyVisibility(for: self.session.status)
                self.startObservingSettings()
            }
        }
    }

    private func applyVisibility(for status: RecordingSession.Status) {
        // Master switch: the floating widget is opt-in (Settings →
        // Capture → "Show floating widget"). When OFF, the panel
        // never appears regardless of session state.
        //
        // When ON, the widget is visible across ALL session states
        // including `.idle`. Pre-1.0.3 the panel hid itself at
        // idle, which meant a freshly-launched Daisy with no
        // active recording showed nothing — users couldn't see
        // Daisy was running until they hit the hotkey blind.
        // Always-visible-when-enabled is the right default; users
        // who want it gone can flip the master switch off or
        // pick "Hide for N minutes" from the right-click menu.
        guard settings.floatingWidgetEnabled else {
            hide()
            return
        }
        show()
    }

    /// Re-evaluate visibility against the current session state.
    /// Called by MainView when `settings.floatingWidgetEnabled`
    /// flips, so the widget appears/disappears the moment the
    /// toggle changes without needing a status change to retrigger.
    func reevaluateVisibility() {
        applyVisibility(for: session.status)
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
        // Sized 59.84×59.84 (was 70.4; −15% 2026-06-05) to match the
        // active daisy geometry (canvasSize 49.5 → 42.075 in DaisyWidget,
        // same ×0.85). The shadow keeps proportional padding around the
        // active state, more for passive (the daisy still shrinks in
        // idle/finished).
        let container = ZStack {
            widget
        }
        .frame(width: 59.84, height: 59.84)
        let hosting = NSHostingController(rootView: container)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = CGColor.clear

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 59.84, height: 59.84),
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
