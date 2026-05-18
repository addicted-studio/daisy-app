//
//  SilenceBubble.swift
//  Daisy
//
//  Small "Are we done?" callout that appears next to the floating
//  daisy widget after a long stretch of silence (or a long pause).
//  Two answers: Stop & save (final transcribe + summary) or Not yet
//  (snooze the prompt for another silence window).
//
//  Styling matches the floating widget's palette — near-black puck
//  fill, white text, orange action accent. The bubble reads as a
//  speech callout coming out of the same surface as the daisy mark
//  itself, not as a generic system tooltip.
//

import SwiftUI

/// Background colour for the bubble — identical to the dark puck the
/// daisy widget sits on (`DaisyWidget.swift` line ~64). Pulled out so
/// any future tweak to the widget body picks the bubble up too.
private let bubbleBackground = Color(red: 0.07, green: 0.07, blue: 0.085)

struct SilenceBubble: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Are we done?")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                Button {
                    onConfirm()
                } label: {
                    Text("Stop & save")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(
                            // Recording-orange accent matches the
                            // widget's centre while the session is
                            // hot — same colour the user is already
                            // associating with "live record" state.
                            Capsule(style: .continuous).fill(Color.daisyRecording)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button {
                    onDismiss()
                } label: {
                    Text("Not yet")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.7)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        // Vertical padding only — the bubble sizes itself to the
        // intrinsic width of its widest child (the HStack of two
        // pill buttons), so horizontal padding plus a fixed
        // `.frame(width:)` is double-counting and produces a
        // ghost gap. Letting the content drive width means
        // "Are we done?" and the buttons sit flush with the
        // bubble edges, with the buttons' own pill padding doing
        // all the breathing-room work.
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(bubbleBackground)
        )
        // Match the widget's drop-shadow values exactly so the
        // bubble and the daisy puck read as one floating surface.
        // Shadow padding (see panel size in FloatingPanelController)
        // gives this room to render without being clipped against
        // the panel's content rect.
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

#Preview {
    SilenceBubble(onConfirm: {}, onDismiss: {})
        .padding(40)
}
