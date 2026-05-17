//
//  SilenceMonitor.swift
//  Daisy
//
//  Detects long stretches of silence during a recording and asks
//  whether the user just forgot to hit Stop. Owned by
//  RecordingSession; pokes a published flag the floating widget
//  binds to so it can pop a "Are we done?" callout next to the
//  daisy mark.
//
//  Heuristic:
//   • Speech threshold: levelDB ≥ -45 dB counts as "someone said
//     something". Below that we consider the room quiet.
//   • Silence window: 3 minutes of continuous quiet during
//     `.recording` triggers the prompt. Pausing the session, hitting
//     Stop, or any sound above threshold resets the clock.
//   • Snooze: if the user dismisses with "Not yet", we don't poke
//     again for another full window. Stop / Pause / Resume also
//     resets the snooze so a fresh recording session starts clean.
//
//  Numbers are intentionally not user-configurable for v1 — easier
//  to ship a sensible default than a settings tab nobody touches.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class SilenceMonitor {
    /// When true, the widget should show "Are we done?" — the
    /// floating panel reads this and renders the bubble; the
    /// session also exposes it via a passthrough property so other
    /// surfaces can react.
    private(set) var questionVisible: Bool = false

    @ObservationIgnored
    private weak var session: RecordingSession?
    @ObservationIgnored
    private var tickTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastSpeechAt: Date?
    @ObservationIgnored
    private var snoozedUntil: Date?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SilenceMonitor")

    private let speechThresholdDB: Float = -45
    private let silenceWindowSec: TimeInterval = 3 * 60
    private let pollIntervalSec: TimeInterval = 5

    init(session: RecordingSession) {
        self.session = session
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Lifecycle hooks called from RecordingSession

    /// Begin monitoring. Called when the session enters `.recording`.
    /// `start()` is idempotent — calling it again while already
    /// running is a no-op.
    func start() {
        if tickTask != nil { return }
        lastSpeechAt = Date()
        questionVisible = false
        snoozedUntil = nil
        tickTask = Task { [weak self] in
            await self?.runLoop()
        }
        log.info("Silence monitor armed")
    }

    /// Pause monitoring without resetting state. Called on session
    /// pause so the silence clock doesn't accumulate through a
    /// human-initiated quiet stretch.
    func pause() {
        tickTask?.cancel()
        tickTask = nil
        questionVisible = false
    }

    /// Resume monitoring after `pause()`. Re-arms the clock from
    /// "now" so the user gets a fresh window after intentional silence.
    func resume() {
        guard tickTask == nil else { return }
        lastSpeechAt = Date()
        tickTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Tear down completely. Called on session stop / reset / failed.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        questionVisible = false
        lastSpeechAt = nil
        snoozedUntil = nil
    }

    /// User dismissed the prompt with "Not yet" — give them a fresh
    /// silence window before nagging again.
    func snooze() {
        questionVisible = false
        snoozedUntil = Date().addingTimeInterval(silenceWindowSec)
        // Reset the speech clock too so we don't immediately re-fire.
        lastSpeechAt = Date()
    }

    /// User explicitly hit "Stop & save" via the bubble — close it
    /// out, the session is being finalised anyway.
    func acknowledge() {
        questionVisible = false
    }

    // MARK: - Internals

    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pollIntervalSec))
            if Task.isCancelled { break }
            tick()
        }
    }

    private func tick() {
        guard let session, session.status == .recording else { return }
        // Any audio above threshold during the last poll resets the
        // silence clock. levelDB is updated by the audio render
        // thread every buffer — by the time we sample it here it
        // reflects the last few ms.
        if session.levelDB >= speechThresholdDB {
            lastSpeechAt = Date()
            if questionVisible { questionVisible = false }
            return
        }
        // Already nudged once and the user snoozed — wait it out.
        if let snoozedUntil, Date() < snoozedUntil {
            return
        }
        let referenceDate = lastSpeechAt ?? Date()
        let quietFor = Date().timeIntervalSince(referenceDate)
        if quietFor >= silenceWindowSec, !questionVisible {
            questionVisible = true
            log.info("Silence prompt shown after \(Int(quietFor), privacy: .public)s of quiet")
        }
    }
}
