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
//   • idle / finished / failed → accent-tinted capsule, "Record"
//   • recording                → orange capsule, "Stop · 01:23"
//   • preparing/stopping/sum.  → dimmed capsule with hourglass
//

import SwiftUI

struct RecordCapsule: View {
    @Bindable var session: RecordingSession

    var body: some View {
        Button(action: handleTap) {
            // 2026-05-25 — HStack spacing 8 → 6 to match the implicit
            // icon-to-text spacing of `Label(systemImage:)` rows in
            // `List(.sidebar)`. Pre-fix the icon-to-text gap inside
            // the capsule was visibly wider than inside the Home /
            // Library / Connections / Settings / About rows above,
            // so even with matching outer width the internal rhythm
            // looked off.
            HStack(spacing: 6) {
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
            // 2026-05-25 — horizontal padding bumped 8 → 12 per Egor's
            // sidebar pass. Pre-bump the 8pt inset (chosen to
            // compensate the Capsule curve so the icon aligned with
            // the sidebar row chip x-position) made the play/pause
            // glyph sit too close to the left curve and the timer
            // too close to the right curve — text "breathed" less
            // than the equivalent padding in the row chips above.
            // 12pt restores air around both ends; the icon x drifts
            // ~4pt inward of the sidebar row chip but the capsule
            // now reads as a self-contained pill rather than an
            // over-stretched one. Stop & save below got the same
            // bump for matched-pair rhythm.
            .padding(.horizontal, 12)
            // 2026-05-25 — bumped vertical padding 8 → 14 (+6 each
            // side = +12pt total height) per Egor's eyeball pass on
            // the sidebar. Previously the capsule felt tight against
            // the row labels above it; with the bigger touch target
            // the Record button now reads as the unambiguous primary
            // action of the sidebar, matches the visual weight of
            // the brand mark + Daisy pill above.
            .padding(.vertical, 14)
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
            .daisyGlass(in: Capsule(style: .continuous))
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
        // 2026-05-25 — idle / finished label changed "Start" → "Record"
        // to match the verb used everywhere else in the app (toolbar
        // play button, dock badge title, hotkey hint "⌘⇧R"). "Start"
        // is generic — start what? — and Daisy's three modes (meeting,
        // voice note, dictation) are all variants of "record". The
        // recording-state labels (Pause / Resume / Stop) stay as
        // standard media verbs once a session is in flight.
        switch session.status {
        case .recording:    return "Pause"
        case .paused:       return "Resume"
        case .preparing:    return "Preparing…"
        case .stopping:     return "Stopping…"
        case .summarizing:  return "Summarizing…"
        case .finished:     return "Record"
        case .failed:       return "Try again"
        case .idle:         return "Record"
        }
    }

    private var fill: Color {
        switch session.status {
        // Colour signals what happens ON CLICK, not current state:
        //   recording → label says "Pause", click moves us to a
        //   calm paused state, so the capsule is grey (no urgency).
        //   paused    → label says "Resume", click re-enters active
        //   recording, so the capsule is orange (the mic dot is
        //   about to come back).
        case .recording:                              return .daisyPaused
        case .paused:                                  return .daisyRecording
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
        case .idle:         return "Record a new session (Space)"
        case .finished:     return "Record another session (Space)"
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
