//
//  RecordingSession+AutoStop.swift
//  Daisy
//
//  Calendar-bound auto-stop: the silence-gated evaluator that stops
//  a session once the bound meeting has ended and the room has gone
//  quiet (or at a hard overrun backstop), plus the manual-start
//  fallback that binds a hotkey-started session to a currently
//  running calendar event so auto-stop still arms. Pure code motion
//  out of RecordingSession.swift — timers and latch flags stay as
//  stored properties on the class.
//

import Foundation
import os

extension RecordingSession {
    // MARK: - Auto-stop (calendar-bound)

    /// Once past endDate+grace, stop only after this much continuous quiet
    /// on BOTH mic and system. A live conversation never has this long a
    /// gap; a finished meeting does.
    private static let autoStopSilenceToStopSec: TimeInterval = 120
    /// Absolute backstop: stop unconditionally this long past the scheduled
    /// end even if audio is still flowing (background music, forgotten
    /// call), so a left-running session can't record forever.
    private static let autoStopMaxOverrunSec: TimeInterval = 30 * 60
    /// Peak-dBFS floor above which mic/system counts as "audible" for
    /// auto-stop gating. Higher than the −80 dB liveness floor: room tone
    /// shouldn't keep a finished meeting alive, but speech easily clears it.
    private static let autoStopAudibleFloorDB: Float = -55
    /// How often the silence-gated evaluator re-checks.
    private static let autoStopEvalIntervalSec: TimeInterval = 10

    /// Schedule the auto-stop fire + 30s warning toast if the
    /// session is bound to a calendar event AND the user has the
    /// auto-stop preference on. No-op otherwise (manual sessions are
    /// never auto-stopped).
    // internal for RecordingSession.swift (called from start()/resume())
    func scheduleAutoStopIfNeeded() {
        cancelAutoStop()
        autoStopSuppressed = false
        autoStopWarned = false
        guard settings.autoStopFromCalendar else {
            autoStopLog.info("scheduleAutoStop: skipped — autoStopFromCalendar=false")
            return
        }
        guard let meeting = boundMeeting else {
            // Most common silent failure pre-1.0.4: user toggled the
            // pref ON but started the recording manually (hotkey /
            // widget) before the calendar tick auto-started it, so
            // boundMeeting was never wired. `start()` now tries to
            // auto-bind via `bindCurrentMeetingIfPossible()`; this
            // log captures the case where even that fallback misses.
            autoStopLog.info("scheduleAutoStop: skipped — no boundMeeting on this session (manual start without matching calendar event in fire window)")
            return
        }
        let now = Date()
        let hardMax = meeting.endDate.addingTimeInterval(Self.autoStopMaxOverrunSec)
        guard hardMax > now else {
            autoStopLog.warning("scheduleAutoStop: meeting '\(meeting.title, privacy: .private)' already past end+maxOverrun (endDate=\(meeting.endDate.description, privacy: .public)) — no timer armed")
            return
        }

        // Silence-gated auto-stop (replaces the old fixed endDate+grace
        // one-shot that cut people off mid-sentence — Egor, 2026-06-01:
        // "стопнул, хотя мы ещё разговаривали"). A repeating evaluator
        // stops only once there's been `autoStopSilenceToStopSec` of quiet
        // past endDate+grace, or unconditionally at endDate+maxOverrun.
        // See evaluateAutoStop().
        autoStopLastAudibleAt = now
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoStopEvalIntervalSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluateAutoStop() }
        }
        autoStopLog.info("Auto-stop armed (silence-gated) for '\(meeting.title, privacy: .private)': earliest endDate+\(self.settings.autoStopGraceSec, privacy: .public)s then \(Int(Self.autoStopSilenceToStopSec), privacy: .public)s quiet; hard max endDate+\(Int(Self.autoStopMaxOverrunSec), privacy: .public)s")
    }

    /// Try to auto-bind a calendar meeting to the current session
    /// when the user started recording manually (hotkey/widget) but
    /// a calendar event is currently in or near its start window.
    /// Mirrors the `CalendarService.tick()` fire window — `meeting.start
    /// - 30s … meeting.end` — so any meeting we'd have auto-started is
    /// also a meeting we'll auto-bind to. Without this, the tester's
    /// hotkey-start-before-calendar-tick path produced an unbindable
    /// session and silently swallowed the auto-stop preference.
    ///
    /// Idempotent — no-op if `boundMeeting` is already set or no
    /// matching meeting exists. Called from `start()` after `reset()`
    /// has applied any explicit `pendingBoundMeeting`.
    // internal for RecordingSession.swift (called from start()/resume())
    func bindCurrentMeetingIfPossible() {
        guard boundMeeting == nil else { return }
        guard currentMode == .meeting else { return }
        let now = Date()
        let match = CalendarService.shared.upcomingMeetings.first { meeting in
            // Window mirrors CalendarService.tick(): -120s … +30s of
            // start, AND not yet past end. Without the lower bound a
            // long-running all-day "OOO" event flagged as a meeting
            // would bind anything started in the last 8 hours — and
            // auto-stop would fire at the event's far-future end.
            let deltaToStart = meeting.startDate.timeIntervalSince(now)
            let inStartWindow = deltaToStart <= 30 && deltaToStart >= -120
            let stillRunning = meeting.endDate > now
            return inStartWindow && stillRunning
        }
        guard let meeting = match else {
            autoStopLog.info("bindCurrentMeetingIfPossible: no calendar meeting in fire window")
            return
        }
        boundMeeting = meeting
        // Only overwrite the autogenerated `"Meeting yyyy-MM-dd HH:mm"`
        // placeholder (set at line ~577), never a user-typed title.
        // hasPrefix("Meeting ") was too greedy — caught "Meeting with
        // Anna prep" and clobbered intentional user titles.
        if title.isEmpty || Self.isAutoGeneratedMeetingTitle(title) {
            title = meeting.title
        }
        if folder == .inbox { folder = .work }
        // Pre-fill tag from attendee domain (most-frequent
        // external org). Same call site as the auto-binding in
        // start() so manual-start sessions also get the suggestion.
        if tag.isEmpty, let suggested = TagSuggestion.suggest(from: meeting.attendeeEmails) {
            tag = suggested
        }
        autoStopLog.info("bindCurrentMeetingIfPossible: auto-bound to '\(meeting.title, privacy: .private)' (started \(Int(now.timeIntervalSince(meeting.startDate)), privacy: .public)s ago, ends in \(Int(meeting.endDate.timeIntervalSince(now)), privacy: .public)s)")
    }

    /// True iff `s` matches the exact `"Meeting yyyy-MM-dd HH:mm"`
    /// shape produced by `start()` when the user hasn't typed one in.
    /// Uses a precise regex rather than `hasPrefix("Meeting ")` so
    /// a user-typed title that happens to start with "Meeting " is
    /// preserved through auto-bind.
    nonisolated private static func isAutoGeneratedMeetingTitle(_ s: String) -> Bool {
        let pattern = #"^Meeting \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    // internal for RecordingSession.swift (called from stop()/reset()/failFast())
    func cancelAutoStop() {
        autoStopTimer?.invalidate()
        autoStopWarningTimer?.invalidate()
        autoStopTimer = nil
        autoStopWarningTimer = nil
    }

    /// Repeating evaluator (every `autoStopEvalIntervalSec`) for the
    /// silence-gated auto-stop. Stops the session only once it's been
    /// quiet for `autoStopSilenceToStopSec` past endDate+grace, or
    /// unconditionally at endDate+maxOverrun. While anyone is still
    /// talking (mic OR system above the floor), the stop is deferred.
    private func evaluateAutoStop() {
        guard status == .recording || status == .paused, !autoStopSuppressed else {
            cancelAutoStop()
            return
        }
        guard let meeting = boundMeeting else { cancelAutoStop(); return }
        let now = Date()
        let earliest = meeting.endDate.addingTimeInterval(TimeInterval(settings.autoStopGraceSec))
        let hardMax = meeting.endDate.addingTimeInterval(Self.autoStopMaxOverrunSec)

        // Absolute backstop — stop no matter what's still on the line.
        if now >= hardMax {
            if !autoStopWarned { armAutoStopWarningAndStop(silence: false) }
            return
        }

        // Is anyone still talking? Either stream above the floor counts.
        let audible = recorder.levelDB > Self.autoStopAudibleFloorDB
            || systemAudio.peakLevelDB > Self.autoStopAudibleFloorDB
        if audible {
            autoStopLastAudibleAt = now
            // Conversation resumed during a pending stop — call it off.
            if autoStopWarned {
                autoStopWarningTimer?.invalidate()
                autoStopWarningTimer = nil
                autoStopWarned = false
                autoStopLog.info("Auto-stop: audio resumed past scheduled end — stop deferred")
            }
            return
        }

        // Silent right now — only consider stopping once past endDate+grace.
        guard now >= earliest else { return }
        let silentFor = now.timeIntervalSince(autoStopLastAudibleAt ?? earliest)
        if silentFor >= Self.autoStopSilenceToStopSec, !autoStopWarned {
            armAutoStopWarningAndStop(silence: true)
        }
    }

    /// Show the 30 s "Keep going" warning and arm the actual stop. Called
    /// by `evaluateAutoStop` when the quiet/overrun condition is first met.
    /// "Keep going" cancels auto-stop for the rest of the session.
    private func armAutoStopWarningAndStop(silence: Bool) {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        autoStopWarned = true
        let msg = silence
            ? "Meeting's been quiet for a couple of minutes — Daisy will stop & save in 30 seconds."
            : "Meeting has run well past its end — Daisy will stop & save in 30 seconds."
        ToastCenter.shared.showAction(
            msg,
            actionLabel: "Keep going",
            style: .warning,
            duration: .seconds(30)
        ) { [weak self] in
            guard let self else { return }
            self.cancelAutoStop()
            self.autoStopSuppressed = true
            ToastCenter.shared.show("Auto-stop cancelled for this session.", style: .info)
        }
        autoStopWarningTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.performAutoStop() }
        }
    }

    private func performAutoStop() async {
        guard status == .recording || status == .paused, !autoStopSuppressed else { return }
        ToastCenter.shared.show("Meeting ended — stopping & saving.", style: .info, duration: .seconds(2))
        let meetingTitle = boundMeeting?.title ?? title
        await stop()
        // Banner confirms the save completed — surfaces even when
        // Daisy is in the background, which is the common case for
        // an auto-stopped session. Gated on the per-class toggle.
        if settings.notifyOnAutoStop {
            AutoStopNotification.post(meetingTitle: meetingTitle)
        }
    }
}
