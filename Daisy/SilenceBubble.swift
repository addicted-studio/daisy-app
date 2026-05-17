//
//  SilenceBubble.swift
//  Daisy
//
//  Small "Are we done?" callout that appears above the floating
//  daisy widget after a long stretch of silence. Two answers: Stop
//  & save (final transcribe + summary) or Not yet (snooze the
//  prompt for another silence window).
//

import SwiftUI

struct SilenceBubble: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "ear")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.daisyAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Are we done?")
                        .font(.callout.weight(.semibold))
                    Text("It's been quiet for a while.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Button {
                    onConfirm()
                } label: {
                    Label("Stop & save", systemImage: "stop.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .background(
                            Capsule(style: .continuous).fill(Color.daisyBgElevated)
                        )
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.daisyBgPrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
    }
}

#Preview {
    SilenceBubble(onConfirm: {}, onDismiss: {})
        .padding(40)
}
