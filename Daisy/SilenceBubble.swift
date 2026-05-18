//
//  SilenceBubble.swift
//  Daisy
//
//  Small "Are we done?" callout that appears next to the floating
//  daisy widget after a long stretch of silence (or a long pause).
//  Two answers: Stop & save (final transcribe + summary) or Not yet
//  (snooze the prompt for another silence window).
//
//  Styling deliberately mirrors the rest of Daisy's widget surface
//  (warm cream sidebar fill, hairline divider, ~12pt radius) rather
//  than the system .floating panel default — the visual link to the
//  daisy widget is the whole point. Drop-shadow values match the
//  widget's so the two read as one element.
//

import SwiftUI

struct SilenceBubble: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Stripped to a single line — the original two-line layout
            // (ear icon + title + secondary subtitle) read as a system
            // notification, and the subtitle ("It's been quiet for a
            // while.") just restated the trigger. The question is
            // the prompt; the buttons are the answer.
            Text("Are we done?")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.daisyTextPrimary)

            HStack(spacing: 6) {
                Button {
                    onConfirm()
                } label: {
                    // No leading icon — pairs visually with "Not yet"
                    // as plain text in pill chrome.
                    Text("Stop & save")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(
                            Capsule(style: .continuous).fill(Color.daisyAccent)
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
                        .foregroundStyle(Color.daisyTextPrimary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.daisyBgPrimary)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.daisyDivider, lineWidth: 0.7)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 220)
        .background(
            // daisyBgSidebar is the same warm cream the main window
            // sidebar uses — visually ties the bubble to Daisy's
            // surface palette rather than reading as a generic
            // system tooltip.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.daisyBgSidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.7)
        )
        // Match the widget's drop-shadow so the two pieces read as
        // one floating surface, not as two unrelated overlays.
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

#Preview {
    SilenceBubble(onConfirm: {}, onDismiss: {})
        .padding(40)
}
