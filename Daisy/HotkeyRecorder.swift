//
//  HotkeyRecorder.swift
//  Daisy
//
//  SwiftUI control that lets the user record an arbitrary keyboard
//  shortcut by pressing it. Uses `NSEvent.addLocalMonitorForEvents`
//  to grab the next keystroke without any focus / first-responder
//  dance.
//
//  The recorder logic lives on a class coordinator (`KeyCaptureBox`)
//  rather than directly inside the View struct. That sidesteps two
//  traps with `addLocalMonitorForEvents` callbacks:
//   1. Swift 6 strict-concurrency on captured `self` of a struct
//      view — mutations to `@Binding` / `@State` via the captured
//      copy can be elided.
//   2. `Task { @MainActor in … }` queues the state update async,
//      so by the time it runs the monitor has already returned and
//      a fast follow-up key event can race the binding update.
//
//  The box uses `DispatchQueue.main.async` for the state hop — it
//  fires on the next runloop tick, reliably, without going through
//  Swift Concurrency scheduling.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var value: HotkeyChoice
    @State private var isListening = false
    @State private var box = KeyCaptureBox()

    var body: some View {
        Button {
            if isListening {
                box.stop()
                isListening = false
            } else {
                box.start(
                    onCapture: { choice in
                        value = choice
                        isListening = false
                    },
                    onCancel: {
                        isListening = false
                    }
                )
                isListening = true
            }
        } label: {
            HStack(spacing: 6) {
                // Keyboard icon shows ONLY while listening — in
                // idle state a leading icon would visually clash
                // with the shortcut label (e.g. "⌘ ⌃⌥⌘R" reads
                // as ⌘⌃⌥⌘R). The capsule itself is the affordance.
                if isListening {
                    Image(systemName: "keyboard")
                        .font(.caption.weight(.medium))
                }
                Text(displayLabel)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if !isListening && value.keyCode != nil {
                    Button {
                        value = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 120)
            .background(
                Capsule(style: .continuous)
                    .fill(isListening
                          ? Color.daisyAccent.opacity(0.18)
                          : Color.daisyBgSidebar)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isListening
                                  ? Color.daisyAccent
                                  : Color.daisyDivider, lineWidth: 0.7)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(isListening ? "Press the shortcut combination…" : "Click to change shortcut")
        .onDisappear { box.stop() }
    }

    private var displayLabel: String {
        if isListening { return "Press keys…" }
        return value.label
    }
}

// MARK: - Capture coordinator

/// Class coordinator owning the NSEvent monitor + the user-supplied
/// callbacks. Reference-typed so its identity is stable across view
/// re-renders, and so the monitor closure can capture `self`
/// (a class) without struct-value-capture surprises.
private final class KeyCaptureBox {
    private var keyToken: Any?
    private var flagsToken: Any?
    private var onCapture: ((HotkeyChoice) -> Void)?
    private var onCancel: (() -> Void)?

    /// Modifier state tracked via `.flagsChanged` events. macOS 26
    /// observed at user site: keyDown events come through with
    /// modifierFlags == 0x100 (no public modifier set) even when
    /// the user is holding ⌘/⌃/⌥. We track state separately and
    /// merge into the synthetic NSEvent we pass to fromNSEvent.
    private var trackedModifiers: NSEvent.ModifierFlags = []

    deinit {
        if let keyToken { NSEvent.removeMonitor(keyToken) }
        if let flagsToken { NSEvent.removeMonitor(flagsToken) }
    }

    func start(
        onCapture: @escaping (HotkeyChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        stop()
        self.onCapture = onCapture
        self.onCancel = onCancel
        trackedModifiers = []

        // 1. Track modifier press/release via flagsChanged.
        flagsToken = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.trackedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }

        // 2. Catch the actual letter/key press.
        keyToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
    }

    func stop() {
        if let keyToken {
            NSEvent.removeMonitor(keyToken)
            self.keyToken = nil
        }
        if let flagsToken {
            NSEvent.removeMonitor(flagsToken)
            self.flagsToken = nil
        }
        onCapture = nil
        onCancel = nil
        trackedModifiers = []
    }

    /// Returns `nil` to consume the event (so it doesn't propagate
    /// to menu key-equivalents or the focused control), or the
    /// event itself to pass it through unchanged.
    private func handle(event: NSEvent) -> NSEvent? {
        // Merge event-reported modifiers with our flagsChanged-
        // tracked state — on some setups (observed macOS 26 +
        // certain keyboards) keyDown events arrive with no public
        // modifier bits even though the user is holding ⌘/⌃/⌥.
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let effectiveMods = eventMods.union(trackedModifiers)

        if event.keyCode == UInt16(kVK_Escape) {
            let cancel = onCancel
            DispatchQueue.main.async { cancel?() }
            return nil
        }

        if let choice = HotkeyChoice.fromKeyCode(UInt16(event.keyCode), modifierFlags: effectiveMods) {
            let capture = onCapture
            DispatchQueue.main.async { capture?(choice) }
            return nil
        }
        // Bare letter / modifier-less keystroke (not a function key)
        // — beep but stay listening so the user can try a real combo.
        NSSound.beep()
        return nil
    }
}
