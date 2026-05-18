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
//  Heuristic (revised 2026-05-18):
//   • Speech signal: arrival of a new TranscriptSegment with
//     non-empty text. We deliberately do NOT key off the raw mic
//     levelDB because anything above -45 dB resets the clock — and
//     keyboard typing, HVAC, water running, and street noise all
//     clear that bar without WhisperKit producing any text. The
//     transcriber's output is the cleanest "the user is actually
//     speaking" signal we have.
//   • Silence window: 3 minutes since the most recent transcribed
//     segment during `.recording` triggers the prompt. Pausing the
//     session, hitting Stop, or any new transcript content resets
//     the clock.
//   • Snooze: if the user dismisses with "Not yet", we don't poke
//     again for another full window. Stop / Pause / Resume also
//     resets the snooze so a fresh recording session starts clean.
//   • Long pause: when the session sits on .paused for more than
//     5 minutes we also surface the prompt. Pause is intentional
//     (the user pressed it) but "I'll be back in two minutes"
//     turns into "I forgot I left it on" with surprising
//     frequency, and a paused recording quietly draining battery
//     is exactly the failure mode the bubble exists to catch.
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
    private var pausedPromptTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastSpeechAt: Date?
    @ObservationIgnored
    private var snoozedUntil: Date?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SilenceMonitor")

    private let silenceWindowSec: TimeInterval = 3 * 60
    private let pausedWindowSec:  TimeInterval = 5 * 60
    private let pollIntervalSec:  TimeInterval = 5

    init(session: RecordingSession) {
        self.session = session
    }

    deinit {
        tickTask?.cancel()
        pausedPromptTask?.cancel()
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
    /// human-initiated quiet stretch. Replaces the speech-poll loop
    /// with a single-shot pause-prompt timer — see `armPausedTimer`.
    func pause() {
        tickTask?.cancel()
        tickTask = nil
        questionVisible = false
        armPausedTimer()
    }

    /// Resume monitoring after `pause()`. Re-arms the clock from
    /// "now" so the user gets a fresh window after intentional silence.
    func resume() {
        cancelPausedTimer()
        questionVisible = false
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
        cancelPausedTimer()
        questionVisible = false
        lastSpeechAt = nil
        snoozedUntil = nil
    }

    /// User dismissed the prompt with "Not yet" — give them a fresh
    /// silence window before nagging again. Works for both the
    /// recording-silence bubble and the long-pause bubble: the
    /// recording branch resets `snoozedUntil` and `lastSpeechAt`;
    /// if we surfaced the bubble from a pause timer (tickTask is
    /// nil because pause() cancelled it), we additionally re-arm
    /// that timer for another full window.
    func snooze() {
        questionVisible = false
        snoozedUntil = Date().addingTimeInterval(silenceWindowSec)
        lastSpeechAt = Date()
        if tickTask == nil, session?.status == .paused {
            armPausedTimer()
        }
    }

    /// User explicitly hit "Stop & save" via the bubble — close it
    /// out, the session is being finalised anyway.
    func acknowledge() {
        questionVisible = false
        cancelPausedTimer()
    }

    // MARK: - Internals

    /// Schedule a one-shot bubble for the long-pause case. Cancelled
    /// by `resume()`, `stop()`, or re-armed by `snooze()`. Uses a
    /// detached single-sleep Task rather than the poll loop because
    /// nothing about the pause state changes during the wait — we
    /// just need a fuse.
    private func armPausedTimer() {
        cancelPausedTimer()
        let window = pausedWindowSec
        pausedPromptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            // `try?` swallows CancellationError silently — guard
            // here in case the task was torn down during the sleep
            // (resume() / stop() racing the wakeup).
            guard !Task.isCancelled, let self else { return }
            guard
                let session = self.session,
                session.status == .paused,
                !self.questionVisible
            else { return }
            self.questionVisible = true
            self.log.info("Silence prompt shown after \(Int(window), privacy: .public)s on pause")
        }
    }

    private func cancelPausedTimer() {
        pausedPromptTask?.cancel()
        pausedPromptTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pollIntervalSec))
            if Task.isCancelled { break }
            tick()
        }
    }

    private func tick() {
        guard let session, session.status == .recording else { return }

        // Take the most recent transcript segment with non-empty
        // text as the speech signal. Walking from the tail is O(1)
        // in the common case (last segment has text) and at worst
        // O(n) when the latest segments are still being finalised
        // — n is at most a few hundred for hour-long recordings,
        // and tick runs every 5 s, so the cost is negligible.
        let latestSpeechAt = session.segments
            .reversed()
            .first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })?
            .startedAt

        // Whisper produced something newer than what we last saw —
        // user is still talking, reset the silence clock and clear
        // any in-flight prompt.
        if let latestSpeechAt, latestSpeechAt > (lastSpeechAt ?? .distantPast) {
            lastSpeechAt = latestSpeechAt
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
            log.info("Silence prompt shown after \(Int(quietFor), privacy: .public)s without new transcript")
        }
    }
}
