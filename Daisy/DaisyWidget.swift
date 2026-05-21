//
//  DaisyWidget.swift
//  Daisy
//
//  Compact floating puck — 8 teardrop petals around a status-coloured
//  centre. Wispr-Flow-inspired aesthetic: solid dark surface, dense
//  glyph-free centre (colour communicates state), tight padding.
//
//  • Recording / Finished / Failed / Idle — petals are amplitude-driven
//    (FFT bands, mirrored across petals for symmetric blooming).
//  • Preparing / Stopping / Summarizing — a "shimmer" sweep rotates
//    around the daisy; petals are uniform mid-length, opacity follows
//    the sweep. Pure black-and-white during summarizing.
//

import SwiftUI
import AppKit

struct DaisyWidget: View {
    let session: RecordingSession
    /// Called by the right-click context menu when the user picks
    /// "Hide for N seconds". The panel controller owns the actual hide
    /// + restore timer. Defaults to a no-op for SwiftUI Previews.
    var onHideRequest: (TimeInterval) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow

    /// Scales the whole daisy briefly when the session lands in
    /// `.finished` — the "celebration" pop that finishes the loader
    /// arc (shimmer rotates → bounce → settle into white).
    @State private var celebrationScale: CGFloat = 1.0

    /// Daisy shrinks in "passive" states (idle, finished) so it sits
    /// less prominently after recording is done. Full size during
    /// active work (recording / preparing / summarizing / failed).
    private var passiveScale: CGFloat {
        switch session.status {
        case .idle, .finished: return 0.66
        default: return 1.0
        }
    }

    private let petalCount = 8
    private let basePetalLength: CGFloat = 7
    private let maxPetalLength: CGFloat = 18
    private let petalWidth: CGFloat = 7
    private let centerSize: CGFloat = 10
    private let canvasSize: CGFloat = 56
    private let petalGap: CGFloat = 0.5

    var body: some View {
        // One TimelineView wraps everything so the view tree is stable
        // across status transitions (recording → stopping → summarizing).
        // Status only changes computed values per petal (amplitude +
        // colour), never the view identity — that fixed the "petals
        // fall apart" flicker we used to get on stop.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let status = session.status
            let mode = session.currentMode
            let summaryGen = session.summaryGenerationState
            let bands = session.spectrumBands
            let sweep = Self.computeSweep(from: context.date)
            let center = centerColor(for: status, mode: mode, summaryGen: summaryGen, sweep: sweep)

            ZStack {
                Circle()
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.085))

                ForEach(0..<petalCount, id: \.self) { i in
                    let petalAngle = Double(i) * 360.0 / Double(petalCount)
                    Petal(
                        amplitude: amplitudeFor(petalIndex: i, bands: bands, status: status),
                        angleDegrees: petalAngle,
                        color: petalColor(petalAngle: petalAngle, sweep: sweep, status: status),
                        width: petalWidth,
                        baseLength: basePetalLength,
                        maxLength: maxPetalLength,
                        centerSize: centerSize,
                        gap: petalGap
                    )
                }

                Circle()
                    .fill(center)
                    .frame(width: centerSize, height: centerSize)
                    .shadow(color: center.opacity(0.55), radius: 2.5, x: 0, y: 0)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        // Combined scale: celebration pop × passive-state shrink.
        // The pop is driven by `onChange` (spring); the passive shrink
        // animates via the implicit `animation(_:value:)` below.
        .scaleEffect(celebrationScale * passiveScale)
        .animation(.easeInOut(duration: 0.35), value: passiveScale)
        // Shadow needs room — the panel is sized larger than canvasSize
        // (FloatingPanelController wraps the widget in an 80×80 ZStack)
        // so this blur isn't clipped against the panel edge.
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        .contentShape(Circle())
        .onTapGesture {
            togglePrimary()
        }
        .contextMenu { contextMenuItems }
        .onChange(of: session.status) { _, newStatus in
            playCelebrationIfFinished(newStatus)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .help(tooltip)
    }

    /// Two-stage spring bounce when the session reaches `.finished`.
    /// Reads as: shimmer was spinning → daisy "lands" → petals settle.
    private func playCelebrationIfFinished(_ status: RecordingSession.Status) {
        guard case .finished = status else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) {
            celebrationScale = 1.18
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.spring(response: 0.40, dampingFraction: 0.65)) {
                celebrationScale = 1.0
            }
        }
    }

    // MARK: - Right-click context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        // Primary actions adapt to the current state. Click-to-toggle
        // on the widget handles the pause/resume flow; the right-click
        // menu is where Stop & save lives because it's destructive and
        // shouldn't be a stray tap.
        switch session.status {
        case .recording:
            Button {
                session.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            Button {
                Task { await session.stop() }
            } label: {
                Label("Stop & save", systemImage: "stop.fill")
            }
        case .paused:
            Button {
                Task { await session.resume() }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            Button {
                Task { await session.stop() }
            } label: {
                Label("Stop & save", systemImage: "stop.fill")
            }
        case .idle, .finished, .failed:
            Button {
                Task { await session.start() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
            }
        case .preparing, .stopping, .summarizing:
            EmptyView()
        }

        Divider()

        Button {
            copyLastTranscript()
        } label: {
            Label("Copy last transcript", systemImage: "doc.on.doc")
        }
        .disabled(!hasContent)

        Button {
            AppNavigation.shared.section = .library
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Library…", systemImage: "books.vertical")
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Divider()

        Menu {
            Button("Hide for 15 minutes") { onHideRequest(15 * 60) }
            Button("Hide for 1 hour")     { onHideRequest(60 * 60) }
            Button("Hide for the day")    { onHideRequest(8 * 60 * 60) }
        } label: {
            Label("Hide…", systemImage: "eye.slash")
        }

        Button {
            AppNavigation.shared.section = .settings
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button(role: .destructive) {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Daisy", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private func canStartFromHere(_ status: RecordingSession.Status) -> Bool {
        switch status {
        case .idle, .finished, .failed: return true
        default: return false
        }
    }

    private var hasContent: Bool {
        session.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private func copyLastTranscript() {
        let text = session.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "[\($0.source.displayLabel)] \($0.text)" }
            .joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Petal amplitude / colour (driven inside the single TimelineView)

    /// Compute the petal's amplitude (0…1) for the current status.
    /// During recording → spectrum bands (mirrored for symmetry).
    /// During processing → fixed mid-length so the daisy reads as a
    /// steady "loader" puck while Whisper / the LLM chews.
    /// Idle / finished / failed → smaller settled position.
    private func amplitudeFor(
        petalIndex: Int,
        bands: [Float],
        status: RecordingSession.Status
    ) -> Float {
        switch status {
        case .recording:
            let half = petalCount / 2
            let bandIndex = petalIndex < half
                ? petalIndex
                : (petalCount - 1 - petalIndex)
            guard bandIndex < bands.count else { return 0.12 }
            return max(0.12, bands[bandIndex])
        case .preparing, .stopping, .summarizing:
            return 0.60
        case .paused:
            // Paused reads as "held" — petals settled, not animating
            // with the (now-zero) spectrum bands.
            return 0.30
        case .idle, .finished, .failed:
            return 0.30
        }
    }

    /// Compute the petal's colour for the current status. During
    /// processing the colour shimmers (sweep-driven opacity) so the
    /// daisy reads as a loader. Other states use static near-white.
    private func petalColor(
        petalAngle: Double,
        sweep: Double,
        status: RecordingSession.Status
    ) -> Color {
        switch status {
        case .preparing, .stopping, .summarizing:
            let opacity = Self.shimmerOpacity(petalAngle: petalAngle, sweep: sweep)
            return Color.white.opacity(opacity)
        case .recording:
            return Color(white: 0.97)
        case .paused:
            // Slightly dimmer than recording so paused reads as
            // "still here, but quiet".
            return Color.white.opacity(0.78)
        case .idle:
            return Color.white.opacity(0.72)
        case .finished, .failed:
            return Color(white: 0.92)
        }
    }

    /// Continuously-advancing sweep angle (0…360) for shimmer + any
    /// future time-driven effects. Pulls `t` into a small range before
    /// multiplying by the angular rate so Double precision doesn't
    /// degrade on a 25-year-old timestamp.
    private static func computeSweep(from date: Date) -> Double {
        let cyclePeriod: Double = 360.0 / 220.0   // ~1.636 s/rev
        let raw = date.timeIntervalSinceReferenceDate
        let phase = raw.truncatingRemainder(dividingBy: cyclePeriod) / cyclePeriod
        return phase * 360.0
    }

    /// Smooth comet pulse — every petal is always clearly visible
    /// (baseline 0.55 so they read on the black puck), with a peak
    /// brightening as the sweep crosses each petal and a gentle 120°
    /// trailing fade behind.
    private static func shimmerOpacity(petalAngle: Double, sweep: Double) -> Double {
        var delta = (sweep - petalAngle).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        let trailDeg = 120.0
        let baseline = 0.55
        let peak = 1.0
        if delta < trailDeg {
            return baseline + (peak - baseline) * (1 - delta / trailDeg)
        }
        return baseline
    }

    /// True if Whisper is mid-download or mid-load. Used to fork
    /// the .preparing state's visual cue from "stream startup, ~1s"
    /// to "first-time model setup, 1-3 minutes" — the latter must
    /// LOOK different or the user assumes the app is hung.
    private var isWhisperWarmingUp: Bool {
        switch WhisperEngine.shared.state {
        case .downloading, .loading, .notLoaded: return true
        case .ready, .failed:                    return false
        }
    }

    private func centerColor(
        for status: RecordingSession.Status,
        mode: RecordingSession.RecordingMode,
        summaryGen: RecordingSession.SummaryGenerationState,
        sweep: Double
    ) -> Color {
        // "Summary cooking" indicator — when status is .finished but
        // the post-Stop detached task is still running summarize +
        // autoSend, fade the centre to amber and pulse the opacity
        // so the widget reads as "working in the background" without
        // taking over the orange recording signal. Deliberately in
        // the warm-amber family (matches the landing's
        // `--color-petal-center` and the in-app `daisyCenterIdle`)
        // so it's a calmer cousin of recording orange — never
        // confused with "still capturing".
        if case .finished = status, summaryGen == .generating {
            // 0.55 → 0.95 → 0.55 over a ~3 s cycle (sweep is the
            // 0…1 sweep already used for petal shimmer; doubling
            // here gives a slightly slower beat).
            let pulse = 0.55 + 0.40 * (0.5 + 0.5 * sin(sweep * .pi))
            return Color.daisyCenterIdle.opacity(pulse)
        }
        switch status {
        // Recording — center hue encodes the active mode so the
        // user can tell at a peripheral glance which gesture they
        // triggered:
        //   • meetings   → macOS systemOrange (inherits the OS mic-active dot)
        //   • dictation  → vivid lilac (creative output, ⌘V-bound)
        //   • voiceNote  → pink-coral (intimate, personal capture)
        // All three live on the same volume / saturation so no mode
        // reads as "less important" than another — they're sibling
        // states of the same recording action.
        case .recording:
            switch mode {
            case .meeting:   return .daisyRecording
            case .dictation: return .daisyDictation
            case .voiceNote: return .daisyVoiceNote
            }
        // Paused = cool neutral gray. Deliberately OUT of the
        // warm orange/amber family — orange means "live capture",
        // so paused has to read as "not live" at a glance. Stays
        // visually distinct from idle (white) and finished (white)
        // by keeping the centre filled rather than ghostly.
        case .paused: return Color.daisyPaused
        // .preparing forks by whether Whisper still needs to download
        // or load — that path is multi-minute on first run, so we
        // pulse the centre amber (same hue as "summary cooking") to
        // tell the user "this is going to take a while, not stuck".
        // Stream-startup .preparing (model already loaded) stays
        // plain white — fast, not worth a special signal.
        case .preparing:
            if isWhisperWarmingUp {
                let pulse = 0.55 + 0.40 * (0.5 + 0.5 * sin(sweep * .pi))
                return Color.daisyCenterIdle.opacity(pulse)
            }
            return Color.white.opacity(0.92)
        // Finished + processing → plain white. The "done" celebration
        // is the scale-pop animation, not a colour change.
        case .stopping, .summarizing, .finished: return Color.white.opacity(0.92)
        case .failed: return .daisyError
        case .idle: return Color.white.opacity(0.55)
        }
    }

    // MARK: - Strings

    private var tooltip: String {
        // Surface the post-Stop summary phase even though status is
        // already `.finished` — the user just hit Stop and is
        // wondering "is anything still happening?".
        if case .finished = session.status,
           session.summaryGenerationState == .generating {
            return "Generating summary…"
        }
        switch session.status {
        case .idle: return "Click to record"
        case .recording: return "Click to pause"
        case .paused: return "Click to resume · right-click for Stop & save"
        case .preparing:
            // First-record path on a fresh install spends most of its
            // wait in Whisper download/load (1-3 minutes for the 626 MB
            // model). Surface the real progress so the user knows the
            // app isn't hung.
            switch WhisperEngine.shared.state {
            case .downloading(let p):
                return "Downloading transcription model… \(Int(p * 100))%"
            case .loading(let status):
                return "Loading transcription model · \(status)"
            case .notLoaded:
                return "Setting up transcription model…"
            default:
                return "Preparing…"
            }
        case .stopping: return "Stopping…"
        case .summarizing: return "Summarizing…"
        case .finished: return "Done · click to record again"
        case .failed(let msg): return msg
        }
    }

    private var accessibilityLabel: String {
        if case .finished = session.status,
           session.summaryGenerationState == .generating {
            return "Daisy. Recording finished. Summary still generating in the background."
        }
        switch session.status {
        case .idle: return "Daisy. Start recording."
        case .recording: return "Daisy. Recording. Tap to pause."
        case .paused: return "Daisy. Paused. Tap to resume."
        case .preparing: return "Daisy. Preparing to record."
        case .stopping: return "Daisy. Stopping."
        case .summarizing: return "Daisy. Summarizing transcript."
        case .finished: return "Daisy. Recording finished."
        case .failed: return "Daisy. Recording failed."
        }
    }

    private var accessibilityValue: String {
        switch session.status {
        case .failed(let msg): return msg
        default: return tooltip
        }
    }

    // MARK: - Actions

    private func togglePrimary() {
        switch session.status {
        case .recording:
            session.pause()
        case .paused:
            Task { await session.resume() }
        case .preparing, .stopping, .summarizing:
            return
        default:
            Task { await session.start() }
        }
    }
}

// MARK: - Teardrop petal shape (drop / leaf form)

/// Petal pointing "up" in unrotated form. Rounded apex at the top, max
/// width slightly below the apex (the "shoulder"), tapers smoothly down
/// to a small rounded root cap. Cubic Beziers with horizontal tangents
/// at the apex — no "mushroom" silhouette.
struct TeardropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        let apexY: CGFloat = 0
        let rootR = w * 0.20
        let rootCenterY = h - rootR
        let apexPull = w * 0.42
        let shoulderX = w * 0.94
        let shoulderY = h * 0.32
        let waistPull = w * 0.04

        path.move(to: CGPoint(x: w / 2, y: apexY))

        path.addCurve(
            to: CGPoint(x: w / 2 + rootR, y: rootCenterY),
            control1: CGPoint(x: w / 2 + apexPull, y: apexY),
            control2: CGPoint(x: shoulderX, y: shoulderY)
        )

        path.addQuadCurve(
            to: CGPoint(x: w / 2 + rootR, y: rootCenterY + 0.1),
            control: CGPoint(x: w / 2 + rootR - waistPull, y: rootCenterY)
        )

        path.addArc(
            center: CGPoint(x: w / 2, y: rootCenterY),
            radius: rootR,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: false
        )

        path.addCurve(
            to: CGPoint(x: w / 2, y: apexY),
            control1: CGPoint(x: w - shoulderX, y: shoulderY),
            control2: CGPoint(x: w / 2 - apexPull, y: apexY)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Petal subview

private struct Petal: View, Equatable {
    let amplitude: Float
    let angleDegrees: Double
    let color: Color
    let width: CGFloat
    let baseLength: CGFloat
    let maxLength: CGFloat
    let centerSize: CGFloat
    let gap: CGFloat

    var body: some View {
        let length = baseLength + (maxLength - baseLength) * CGFloat(amplitude)
        let offsetY = -(centerSize / 2 + length / 2 + gap)

        TeardropShape()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: offsetY)
            .rotationEffect(.degrees(angleDegrees))
            .animation(.easeOut(duration: 0.10), value: amplitude)
    }
}

#Preview {
    DaisyWidget(session: RecordingSession(settings: AppSettings()))
        .padding(20)
}
