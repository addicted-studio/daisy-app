//
//  RecordCapsule.swift
//  Daisy
//
//  Liquid Glass record-button that lives in the sidebar of MainView.
//  Replaces the giant Start/Stop button that used to dominate
//  HomeView. The capsule shape reads as a system control (similar to
//  Voice Memos / iOS Control Center), and the colour transition from
//  cool accent → system orange does the heavy lifting visually —
//  "you're now recording" without needing a textbook explanation.
//
//  States:
//   • idle / finished / failed → accent-tinted capsule, "Start"
//   • recording                → orange capsule, "Stop · 01:23"
//   • preparing/stopping/sum.  → dimmed capsule with hourglass
//

import SwiftUI

struct RecordCapsule: View {
    @Bindable var session: RecordingSession

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                Text(label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if session.status == .recording || session.status == .paused {
                    Text(formatTime(session.elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .glassEffect(in: Capsule(style: .continuous))
            .animation(.easeInOut(duration: 0.18), value: session.status)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(isDisabled)
        .help(helpText)
    }

    // MARK: - Action

    private func handleTap() {
        // Sidebar capsule mirrors the widget: tap toggles
        // pause/resume during an active session. Stop & save is the
        // dedicated Stop button in the popover / kebab — not here.
        switch session.status {
        case .recording:
            session.pause()
        case .paused:
            Task { await session.resume() }
        case .idle, .finished, .failed:
            Task { await session.start() }
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    // MARK: - Style per state

    private var icon: String {
        switch session.status {
        case .recording:                              return "pause.fill"
        case .paused:                                  return "play.fill"
        case .preparing, .stopping, .summarizing:     return "hourglass"
        default:                                       return "record.circle"
        }
    }

    private var label: String {
        switch session.status {
        case .recording:    return "Pause"
        case .paused:       return "Resume"
        case .preparing:    return "Preparing…"
        case .stopping:     return "Stopping…"
        case .summarizing:  return "Summarizing…"
        case .finished:     return "Start"
        case .failed:       return "Try again"
        case .idle:         return "Start"
        }
    }

    private var fill: Color {
        switch session.status {
        case .recording:                              return .daisyRecording
        case .paused:                                  return .daisyPaused
        case .preparing, .stopping, .summarizing:     return Color.gray.opacity(0.40)
        case .failed:                                  return .daisyError
        // Idle Start uses the same orange family as recording — the
        // sidebar capsule is THE record affordance, so wearing the
        // mic-active colour even at rest is honest. State change
        // still reads clearly via icon (record.circle → stop.fill),
        // label (Start → Stop), timer, and the pulse halo.
        default:                                       return .daisyRecording
        }
    }

    private var foreground: Color {
        switch session.status {
        case .recording, .preparing, .stopping,
             .summarizing, .failed:                   return .white
        default:                                       return .white
        }
    }

    private var stroke: Color {
        Color.white.opacity(0.12)
    }

    private var isDisabled: Bool {
        switch session.status {
        case .preparing, .stopping, .summarizing:     return true
        default:                                       return false
        }
    }

    private var helpText: String {
        switch session.status {
        case .recording:    return "Pause (Space)"
        case .paused:       return "Resume (Space)"
        case .idle:         return "Start a new recording (Space)"
        case .finished:     return "Start another recording (Space)"
        case .failed:       return "Try recording again"
        default:            return ""
        }
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
