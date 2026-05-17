//
//  HotkeyRecorder.swift
//  Daisy
//
//  SwiftUI control that lets the user record an arbitrary keyboard
//  shortcut by pressing it. Wraps an NSView-backed first responder
//  that captures `keyDown` while focused and converts the next valid
//  key+modifier press into a `HotkeyChoice` via
//  `HotkeyChoice.fromNSEvent(_:)`.
//
//  Visual states:
//    • Idle      — shows current shortcut label, click to record
//    • Listening — shows "…" placeholder, captures next keystroke
//
//  Usage (Settings):
//      HotkeyRecorder(value: $settings.recordHotkey)
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var value: HotkeyChoice
    @State private var isListening = false

    var body: some View {
        Button {
            isListening.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isListening ? "ear" : "command")
                    .font(.caption.weight(.medium))
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
        .background(
            KeyCaptureView(isCapturing: $isListening, value: $value)
                .frame(width: 0, height: 0)
        )
        .help(isListening ? "Press the shortcut combination…" : "Click to change shortcut")
    }

    private var displayLabel: String {
        if isListening { return "Press keys…" }
        return value.label
    }
}

// MARK: - NSView-backed first responder for key capture

/// Hidden NSView that becomes first responder when `isCapturing` is
/// true, captures the next valid `NSEvent.keyDown` with modifiers,
/// and writes the result back as a `HotkeyChoice`. Escape cancels.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var isCapturing: Bool
    @Binding var value: HotkeyChoice

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = { capturedChoice in
            self.value = capturedChoice
            self.isCapturing = false
        }
        view.onCancel = {
            self.isCapturing = false
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        if isCapturing {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

final class KeyCaptureNSView: NSView {
    var onCapture: ((HotkeyChoice) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Escape always cancels.
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        if let choice = HotkeyChoice.fromNSEvent(event) {
            onCapture?(choice)
        } else {
            NSSound.beep()    // bare key without modifier — invalid
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // No-op: we only commit on a full keyDown with non-modifier
        // key, so modifier-only events shouldn't trigger anything.
    }
}
