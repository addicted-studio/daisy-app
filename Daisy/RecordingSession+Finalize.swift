//
//  RecordingSession+Finalize.swift
//  Daisy
//
//  Everything that happens to a session after capture has stopped:
//  the detached post-Stop pipeline (final Whisper pass → speaker
//  profile matching → transcript re-render → summary → auto-send →
//  audio purge), the auto-send fan-out with its `.send_failures.json`
//  sidecar, and the StoredSession / MeetingExportData snapshot
//  builders the exporters consume. Pure code motion out of
//  RecordingSession.swift — `stop()` itself stays in the main file.
//

import Foundation
import os

/// Shared JSON coders configured for Daisy's `.send_failures.json`
/// sidecar (and any future per-session JSON file that wants the
/// same ergonomics — pretty-printed, deterministic key order,
/// ISO 8601 timestamps that a human can read in a terminal).
///
/// File-scope `extension` so the encoder/decoder live next to the
/// `SendFailureRecord` consumer without polluting every other JSON
/// path in the app.
nonisolated extension JSONEncoder {
    static var daisySendFailureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var daisySendFailureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension RecordingSession {
    /// Detached post-Stop pipeline. Runs everything that used to
    /// block `.stopping` for minutes on long sessions:
    ///
    ///   1. **Final Whisper pass** on mic + system (parallel). This
    ///      is the heavy work — 237s observed on a 20-min session in
    ///      the 2026-05-27 log report. Used to sit inline in
    ///      `Transcriber.stop()`, holding `status = .stopping` until
    ///      it returned and locking the user out of starting a new
    ///      recording. Now it runs here so Stop is snappy.
    ///   2. **Speaker profile matching** — needs the final-pass
    ///      `speakerCentroids`, so it can only run after (1).
    ///   3. **Re-render transcript.md** with final-quality segments.
    ///      The inline path in `stop()` already wrote a live-quality
    ///      transcript.md; we overwrite it here with the polished
    ///      version.
    ///   4. **Summary** (if `willSummarize`) → write summary.json.
    ///   5. **Auto-send** to Notion / MCP destinations.
    ///   6. **Audio purge** if delete-after-transcription mode is on.
    ///
    /// Each stage checks `Task.isCancelled` and that `sessionDirectory`
    /// still matches the captured session ID — either guard fires if
    /// `start()` already kicked off a new recording on top of this
    /// one, in which case we bail without touching the new session's
    /// state. The render+write pair runs SYNCHRONOUSLY without an
    /// intervening await so MainActor scheduling guarantees no other
    /// task can mutate `segments` between the snapshot and the disk
    /// write.
    ///
    /// **Ticket ownership.** This function does NOT touch
    /// `sessionsFolderTicket`. The caller transferred ownership of
    /// the security-scoped ticket to the spawning Task via a local
    /// snapshot + `defer { snapshot?.release() }` — see the
    /// `Task { [ticketSnapshot] in ... }` block above. Doing it
    /// here would race against `start()` putting M2's ticket in the
    /// same slot (the pre-1.0.3 bug).
    // internal for RecordingSession.swift (called from stop())
    func finalizePostStop(
        sessionID: String,
        directory: URL,
        title: String,
        localeHint: String?,
        willSummarize: Bool,
        generation: UInt,
        micArchiveURLs: [URL],
        systemArchiveURLs: [URL]
    ) async {
        // OSSignpost ranges around each slow phase. Lets
        // `xctrace export --xpc Daisy --tracing-key=signposts` show
        // a user "your 4-minute finalize spent 237s in final_pass,
        // 32s in summarize, 1.2s in auto_send". Ships nothing
        // off-device — Apple System Log only. The signpost subsystem
        // matches the logger subsystem so they coalesce in
        // Console.app.
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // Helper to bail cleanly when the session rotated under us.
        // Resets the generation state (only meaningful for the
        // willSummarize path, since the no-summary path never called
        // beginGenerating) and clears summaryTask — but ONLY if the
        // slot still points at us. If a fresh `stop()` has spawned a
        // newer task while we were inside Whisper, the slot now
        // holds that task's reference and nilling it would lose the
        // handle. See `summaryTaskGeneration` doc for the full race.
        @MainActor func bailRotated(stage: String) async {
            log.info("Finalize: \(stage, privacy: .public) — session rotated, bailing")
            if willSummarize {
                summaryGenerationState = .failed("cancelled")
                await SessionStore.shared.finishGenerating(sessionID)
            }
            if generation == summaryTaskGeneration {
                summaryTask = nil
            }
        }

        // ── Stage 1: Final Whisper pass ──────────────────────────────
        //
        // Both transcribers run their final pass concurrently. Each
        // re-runs Whisper over the COMPLETE on-disk `.caf` archive for
        // its stream (decoded from disk inside runFinalPass), not the
        // 30-min-capped in-memory buffer — so the saved transcript
        // covers the whole recording even when live transcription fell
        // behind and the rolling buffer trimmed un-transcribed audio
        // (the long/dense-meeting gap). Sessions with no archive
        // (transcript-only / "don't record audio") fall back to the
        // buffer inside runFinalPass. On an M-series Mac this is CPU-
        // bound on the Neural Engine; on a 20-min mic session it clocks
        // ~237s in production logs, which is why it runs off the inline
        // Stop path.
        //
        // `runFinalPass` is wrapped to flip `Transcriber.isRunning =
        // false` at the end — capture stopped in stop(), but
        // isRunning is intentionally held true between stopCapture()
        // and runFinalPass() because the final pass still mutates
        // committedSegments + speakerCentroids on the same instance.
        let finalPassState = signposter.beginInterval("final_pass", id: signposter.makeSignpostID())
        let t_final = Date()
        // EXPERIMENTAL (opt-in, off by default): pin the remote diarizer to
        // the calendar attendee count (minus you) for this final pass.
        // numClusters is a hard constraint and the invite list is a noisy
        // proxy (no-shows / uninvited / one person on two devices), so only
        // for calendar-bound sessions with a sane count. See AppSettings.
        if settings.diarizeUseAttendeeCountHint,
           let attendees = boundMeeting?.attendees,
           attendees.count >= 2 {
            systemTranscriber.speakerCountHint = max(1, attendees.count - 1)
        }
        async let micFinal: Void = micTranscriber.runFinalPass(archiveURLs: micArchiveURLs)
        async let sysFinal: Void = systemTranscriber.runFinalPass(archiveURLs: systemArchiveURLs)
        _ = await (micFinal, sysFinal)
        signposter.endInterval("final_pass", finalPassState)
        log.info("post-stop final_pass: \(ms(t_final), privacy: .public)ms")

        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            await bailRotated(stage: "after final_pass")
            return
        }

        // ── Stage 2: Speaker profile matching ────────────────────────
        //
        // Reads system-side speakerCentroids that the final pass just
        // populated, looks each one up in SpeakerProfileStore, and
        // writes speakers.json. Without the final pass first, this
        // would silently no-op on long sessions where the live
        // diarizer hadn't yet committed full-session centroids.
        let matchState = signposter.beginInterval("speaker_match", id: signposter.makeSignpostID())
        let t_match = Date()
        applySpeakerProfileMatches()
        signposter.endInterval("speaker_match", matchState)
        log.info("post-stop speaker_match: \(ms(t_match), privacy: .public)ms")

        // ── Stage 3: Re-render transcript.md with final-quality data ─
        //
        // The inline path in stop() wrote a transcript.md from
        // live-accumulated segments so the user has SOMETHING the
        // moment they hit Stop. Now we overwrite it with the polished
        // version. Render + write run as a tight synchronous pair
        // (no await in between) so MainActor scheduling guarantees no
        // other task can mutate `segments` while we're snapshotting.
        let reRenderState = signposter.beginInterval("re_render_md", id: signposter.makeSignpostID())
        let t_reRender = Date()
        let md = MarkdownExporter.renderMarkdown(session: self)
        signposter.endInterval("re_render_md", reRenderState)
        log.info("post-stop re_render_md: \(ms(t_reRender), privacy: .public)ms, \(md.count, privacy: .public) bytes")

        let reWriteState = signposter.beginInterval("re_write_md", id: signposter.makeSignpostID())
        let t_reWrite = Date()
        let mdURL = directory.appendingPathComponent("transcript.md")
        do {
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            // Don't toast on re-write failure — the user already has
            // the live-quality transcript.md from stop(), so this is
            // a quality regression rather than data loss. Logged so
            // the next `log show` pass catches it.
            log.error("Failed to re-write transcript.md: \(error.localizedDescription, privacy: .public)")
        }
        signposter.endInterval("re_write_md", reWriteState)
        log.info("post-stop re_write_md: \(ms(t_reWrite), privacy: .public)ms")

        // ── Stage 3b: Screen-content OCR ─────────────────────────────
        //
        // If screenshots were captured, OCR them on-device (Vision),
        // dedup near-identical frames, and append a "## Shared on screen"
        // section to transcript.md. Runs BEFORE the History refresh below
        // so SessionStore parses the screen text into the session's
        // searchable body, and BEFORE the summary (Stage 4) so a metric
        // shown on a slide can land in the notes even if never spoken.
        // Fully local; skipped entirely when the feature is off or
        // nothing was captured.
        var screenSharedText = ""
        if settings.screenshotsEnabled {
            let screenshotsDir = directory.appendingPathComponent("screenshots", isDirectory: true)
            let ocrState = signposter.beginInterval("screen_ocr", id: signposter.makeSignpostID())
            let t_ocr = Date()
            let ocr = await ScreenTextExtractor.extract(from: screenshotsDir)
            signposter.endInterval("screen_ocr", ocrState)
            if !ocr.markdown.isEmpty {
                screenSharedText = ocr.markdown
                let mdURL = directory.appendingPathComponent("transcript.md")
                if let existing = try? String(contentsOf: mdURL, encoding: .utf8) {
                    let section = "\n\n## Shared on screen\n\n\(ocr.markdown)\n"
                    try? (existing + section).write(to: mdURL, atomically: true, encoding: .utf8)
                }
            }
            log.info("post-stop screen_ocr: \(ms(t_ocr), privacy: .public)ms, \(ocr.distinctScreens, privacy: .public) screens")
        }

        // P1 — recording finished cleanly (transcript.md is final): drop the
        // in-progress marker so this folder is a valid session, not a
        // recoverable husk.
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(SessionStore.recordingMarkerName)
        )

        // Refresh History so any opened SessionDetailView re-reads
        // the freshly-written final-quality transcript instead of
        // sticking with the live snapshot it loaded a few seconds ago.
        await SessionStore.shared.refresh()

        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            await bailRotated(stage: "after re-render")
            return
        }

        // ── Stage 4: Summary (if requested) ──────────────────────────
        //
        // The summarizer takes the final-quality transcript text —
        // built from the same `segments` array we just rendered to
        // disk — and produces a structured MeetingSummary. The pre-
        // 1.0.7.3 path snapshotted `transcript` BEFORE the final
        // Whisper pass landed, which meant the LLM saw live-quality
        // segments while the on-disk transcript.md had final-quality
        // ones. Now both share the same source.
        var summary: MeetingSummary? = nil
        if willSummarize {
            // Fold the OCR'd screen content into what the summarizer sees
            // so slides/dashboards influence the notes (Circleback-style
            // "captured whether said or shown"). Clearly fenced so the
            // model treats it as shown-not-spoken context.
            var transcriptText = fullTranscriptText
            if !screenSharedText.isEmpty {
                transcriptText += "\n\n[Content shared on screen during the meeting — text extracted from slides/documents shown, not spoken:]\n\(screenSharedText)"
            }
            let summarizeState = signposter.beginInterval("summarize", id: signposter.makeSignpostID())
            let t_summarize = Date()
            summary = await summarizer.summarize(
                transcript: transcriptText,
                title: title,
                localeHint: localeHint
            )
            signposter.endInterval("summarize", summarizeState)
            log.info("post-stop summarize: \(ms(t_summarize), privacy: .public)ms, transcript=\(transcriptText.count, privacy: .public) bytes, summary=\(summary != nil ? "ok" : "nil", privacy: .public)")

            if Task.isCancelled {
                summaryGenerationState = .failed("cancelled")
                await SessionStore.shared.finishGenerating(sessionID)
                if generation == summaryTaskGeneration {
                    summaryTask = nil
                }
                return
            }

            if let summary {
                let writeState = signposter.beginInterval("write_summary", id: signposter.makeSignpostID())
                let t_writeSummary = Date()
                let url = directory.appendingPathComponent("summary.json")
                do {
                    let data = try JSONEncoder().encode(summary)
                    try data.write(to: url)
                } catch {
                    log.error("Failed to write summary.json: \(error.localizedDescription, privacy: .public)")
                    ToastCenter.shared.show(
                        String(localized: "Couldn't save summary file. Check Console for details."),
                        style: .error
                    )
                }
                signposter.endInterval("write_summary", writeState)
                log.info("post-stop write_summary: \(ms(t_writeSummary), privacy: .public)ms")
            }
        }

        // ── Stage 5: Auto-send to downstream destinations ────────────
        //
        // If a fresh recording has begun in the meantime (reset()
        // ran), instance state has rotated and autoSend would push
        // the WRONG session to Notion/MCP. Skip — user can resend
        // manually from History.
        if Task.isCancelled || sessionDirectory?.lastPathComponent != sessionID {
            await bailRotated(stage: "before auto_send")
            return
        }

        let autoSendState = signposter.beginInterval("auto_send", id: signposter.makeSignpostID())
        let t_autoSend = Date()
        await runAutoSendDestinations()
        signposter.endInterval("auto_send", autoSendState)
        log.info("post-stop auto_send: \(ms(t_autoSend), privacy: .public)ms")

        // ── Stage 6: Audio purge if delete-after-transcription ───────
        //
        // Pipeline is done with the audio (transcript + summary
        // landed on disk, downstream destinations have shipped).
        // Delete-after-transcription mode kicks in here: drop the
        // raw .caf for THIS session immediately.
        //
        // Gating: for the summary path we wait for summary success
        // (so the user can re-summarize from SessionDetailView if it
        // failed). For the no-summary path (voice notes, autoSummarize
        // disabled, provider unavailable) we purge unconditionally —
        // there's no second-chance LLM pass to keep audio around for,
        // and transcript.md is final-quality by this point.
        let canPurge = willSummarize ? (summary != nil) : true
        if canPurge,
           settings.audioRetentionDays == AppSettings.audioRetentionDeleteAfterTranscription {
            AudioRetentionSweep.purgeOneSession(at: directory)
        }

        // Final state flip. The no-summary path never called
        // beginGenerating, so finishGenerating would no-op — skip it
        // entirely to keep the trace clean.
        if willSummarize {
            summaryGenerationState = (summary != nil) ? .ready : .failed("no summary")
            await SessionStore.shared.finishGenerating(sessionID)
        }
        // Same generation guard as bailRotated — see `summaryTaskGeneration`
        // doc for the race we're protecting against.
        if generation == summaryTaskGeneration {
            summaryTask = nil
        }
    }

    // MARK: - Voice fingerprint matching

    /// Walk the system-side diarization centroids, match each one
    /// against the persistent `SpeakerProfileStore`, and write a
    /// `speakers.json` sidecar with the raw centroids so a later
    /// manual rename in SessionDetailView can create/update profiles.
    /// Auto-matched names land in `initialSpeakerMap` for the
    /// MarkdownExporter to embed in the transcript frontmatter.
    private func applySpeakerProfileMatches() {
        let centroids = systemTranscriber.speakerCentroids
        guard !centroids.isEmpty else { return }

        let store = SpeakerProfileStore.shared
        let mode = settings.speakerMatchMode

        // ── 1. Voice fingerprint matching ────────────────────────────
        // Unchanged engine: each detected cluster centroid is looked up
        // in SpeakerProfileStore by cosine similarity. `matched` is the
        // candidate label→name set; whether it's APPLIED depends on the
        // match mode (below). `matchedProfileIDs` lets the email pass
        // avoid double-counting a profile already found by voice.
        // `source` records HOW each label matched for the Suggest UI.
        var matched: [String: String] = [:]
        var source: [String: String] = [:]
        var matchedProfileIDs: Set<UUID> = []
        // `.off` skips recognition entirely — no cross-meeting auto-
        // match. We still fall through to write speakers.json so manual
        // naming + a later switch back to Automatic/Suggest both work.
        if mode != .off {
            for (speakerID, embedding) in centroids {
                if let profile = store.findMatch(for: embedding) {
                    matched[speakerID] = profile.name
                    source[speakerID] = "voice"
                    matchedProfileIDs.insert(profile.id)
                    // profile.name is PII — speakers the user has named
                    // by hand ("John", "Maria"). Speaker ID (Remote A,
                    // B, …) stays public, the name does not.
                    log.info("Voice-matched \(speakerID, privacy: .public) → \(profile.name, privacy: .private)")
                }
            }

            // ── 2. Calendar-attendee email matching ──────────────────
            // When the session is bound to a calendar event, resolve the
            // event's attendee emails to known profiles. Email is a
            // STABLE identity key (voice timbre drifts with mic / cold /
            // speakerphone), so this catches a known person whose voice
            // didn't cluster-match this time. We can only safely assign
            // an email-identified profile to a SPECIFIC transcript label
            // when there's exactly one unmatched remote label and the
            // email resolves to exactly one not-yet-matched profile —
            // otherwise we'd be guessing which voice is whom. The
            // narrower (but correct) cases still reinforce recency via
            // recordMatch and feed the Suggest sidecar.
            if let emails = boundMeeting?.attendeeEmails, !emails.isEmpty {
                var emailProfiles: [SpeakerProfile] = []
                var seenIDs = Set<UUID>()
                for email in emails {
                    if let p = store.findByEmail(email), seenIDs.insert(p.id).inserted {
                        emailProfiles.append(p)
                    }
                }
                // Profiles found by email that voice DIDN'T already pin
                // to a label. These are the ones we might assign/suggest.
                let unpinned = emailProfiles.filter { !matchedProfileIDs.contains($0.id) }
                // Remote labels with no name yet.
                let unmatchedLabels = centroids.keys.filter { matched[$0] == nil }.sorted()
                if unpinned.count == 1, unmatchedLabels.count == 1 {
                    // Unambiguous: one known invitee, one nameless voice.
                    let label = unmatchedLabels[0]
                    let profile = unpinned[0]
                    matched[label] = profile.name
                    source[label] = "email"
                    matchedProfileIDs.insert(profile.id)
                    log.info("Email-matched \(label, privacy: .public) → (calendar attendee)")
                } else if !unpinned.isEmpty {
                    // Ambiguous mapping (multiple known invitees and/or
                    // multiple nameless voices). Don't assign a specific
                    // label — but still note the recognition so recency
                    // bumps. The Suggest UI surfaces these as floating
                    // "known attendee on this call" hints the user can
                    // drop onto any row. We log count only (names PII).
                    log.info("Email-identified \(unpinned.count, privacy: .public) attendee profile(s); ambiguous label mapping, not auto-assigning")
                }
                // Reinforce recency for EVERY email-identified profile,
                // whether or not it got pinned to a label — the person
                // was demonstrably on the call.
                for p in emailProfiles { store.recordMatch(profileID: p.id) }
            }

            // Recency bump for voice-only matches (email matches already
            // bumped above). Skip ids that were email-pinned to avoid a
            // double bump on the same profile.
            for (label, _) in matched where source[label] == "voice" {
                if let embedding = centroids[label],
                   let profile = store.findMatch(for: embedding),
                   !emailBumped(profile.id, boundMeeting?.attendeeEmails, store) {
                    store.recordMatch(profileID: profile.id)
                }
            }
        }

        // ── 3. Apply per match mode ──────────────────────────────────
        switch mode {
        case .automatic:
            // Today's behaviour: matches land in the transcript's
            // speaker map immediately (MarkdownExporter embeds them).
            initialSpeakerMap = matched
        case .suggest:
            // Don't apply — surface as confirmable suggestions. The
            // transcript ships with raw Remote A/B/C; the detail view's
            // Name-the-speakers card reads the suggestions sidecar and
            // offers a one-tap Confirm per row.
            initialSpeakerMap = [:]
            writeSuggestionsSidecar(byLabel: matched, source: source)
        case .off:
            initialSpeakerMap = [:]
        }

        // Persist centroids sidecar regardless of mode / whether matches
        // happened — even an unmatched session needs centroids on disk
        // so the user can name speakers later and we'll know which
        // embedding to associate with the new profile.
        guard let dir = sessionDirectory else { return }
        let url = dir.appendingPathComponent("speakers.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SpeakerCentroidsFile(centroids: centroids))
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("Failed to write speakers.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True if `id` belongs to a profile that the email pass already
    /// bumped this stop (i.e. its email is among the bound event's
    /// attendee emails). Prevents a double recordMatch when a profile
    /// is matched by BOTH voice and email in the same session.
    private func emailBumped(_ id: UUID, _ emails: [String]?, _ store: SpeakerProfileStore) -> Bool {
        guard let emails, !emails.isEmpty else { return false }
        for email in emails {
            if let p = store.findByEmail(email), p.id == id { return true }
        }
        return false
    }

    /// Write the `speaker_suggestions.json` sidecar (Suggest mode only)
    /// and surface a non-blocking toast pointing the user to History to
    /// review. No sidecar / toast when there's nothing to suggest.
    private func writeSuggestionsSidecar(byLabel: [String: String], source: [String: String]) {
        guard !byLabel.isEmpty, let dir = sessionDirectory else { return }
        let url = dir.appendingPathComponent("speaker_suggestions.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SpeakerSuggestionsFile(byLabel: byLabel, source: source))
            try data.write(to: url, options: [.atomic])
            let n = byLabel.count
            ToastCenter.shared.show(
                String(localized: "Daisy recognized \(n) speakers · review in History"),
                style: .info
            )
            log.info("Wrote \(n, privacy: .public) speaker suggestion(s) for review")
        } catch {
            log.error("Failed to write speaker_suggestions.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Auto-send

    /// Fan the just-finished session out to any destination the
    /// user marked as auto-on-save: Notion (per
    /// `settings.autoSendNotion`) and every enabled MCP integration
    /// whose `autoOnSave` flag is on.
    ///
    /// Errors are surfaced as toasts AND persisted into
    /// `.send_failures.json` inside the session directory — pre-1.0.3
    /// behaviour was toast-only, so a Notion 401 (or a Linear MCP
    /// timeout, or a webhook 503) vanished after a few seconds with
    /// no forensic trail. Users would email "I thought it went to
    /// Notion" with nothing to debug. The sidecar gives support a
    /// concrete artifact and lays groundwork for a future "Resend
    /// failed" affordance in History.
    private func runAutoSendDestinations() async {
        let sessionFolderSlug = folder.slug

        // Notion uses the in-memory `MeetingExportData` shape we
        // already hand to the manual Send-to flow — no need to
        // round-trip through StoredSession.
        if settings.autoSendNotion, settings.hasNotionCredentials, !segments.isEmpty,
           Self.folderAllowed(sessionFolderSlug, allowed: settings.autoSendNotionFolders) {
            let export = exportData()
            do {
                let url = try await NotionExporter.shared.createMeetingPage(export)
                ToastCenter.shared.show(String(localized: "Sent to Notion · \(title)"), style: .success)
                // Notion URL stays .private — same reasoning as in
                // NotionExporter: page ID is a capability identifier
                // for the user's workspace.
                log.info("Auto-sent to Notion: \(url.absoluteString, privacy: .private)")
            } catch {
                log.error("Auto-send to Notion failed: \(error.localizedDescription, privacy: .private)")
                ToastCenter.shared.show(String(localized: "Auto-send to Notion failed — retry from History"), style: .warning)
                recordAutoSendFailure(
                    integration: "Notion",
                    kind: "notion",
                    destination: "user's Notion workspace",
                    error: error.localizedDescription
                )
            }
        }

        // MCP integrations need a `StoredSession`; build one from
        // the in-memory state (the matching `SessionStore.refresh`
        // pass that would normally produce it hasn't happened yet).
        let autoIntegrations = MCPIntegrationStore.shared.autoOnSaveIntegrations
            .filter { Self.folderAllowed(sessionFolderSlug, allowed: $0.allowedFolders) }
        guard !autoIntegrations.isEmpty,
              let directory = sessionDirectory else { return }
        let stored = Self.makeStoredSession(
            id: directory.lastPathComponent,
            directory: directory,
            title: title,
            startedAt: startedAt ?? Date(),
            elapsedSec: Int(elapsed.rounded()),
            locale: localeIdentifier,
            segments: segments,
            summary: summarizer.lastSummary,
            folderSlug: sessionFolderSlug,
            kind: sessionKind,
            tag: tag,
            systemAudioStatus: systemAudioStatusValue
        )
        for integration in autoIntegrations {
            let ok = await MCPDispatcher.send(integration, for: stored)
            if !ok {
                // MCPDispatcher already surfaced a toast and logged
                // the detailed error via os_log. The sidecar gets a
                // generic failure record — users grep Console.app
                // by subsystem `app.essazanov.Daisy` category
                // `MCPDispatcher` for the specifics. A future
                // refactor of MCPDispatcher.send() to return
                // (Bool, String?) would let us record the error
                // text here too; not blocking on it for 1.0.3.
                recordAutoSendFailure(
                    integration: integration.name,
                    kind: integration.kind == .mcp ? "mcp" : "webhook",
                    destination: integration.baseURL,
                    error: nil
                )
            }
        }
    }

    /// One entry in the per-session auto-send failure log.
    /// Stored as JSON inside `<sessionDir>/.send_failures.json`.
    ///
    /// Schema is part of the on-disk contract; future versions can
    /// add OPTIONAL fields but must not rename or remove existing
    /// ones — old Daisy versions reading sidecars written by newer
    /// versions should still decode successfully.
    nonisolated struct SendFailureRecord: Codable, Sendable {
        let integration: String     // human-readable name ("Notion", "Linear", "Slack webhook")
        let kind: String            // "notion" | "mcp" | "webhook"
        let destination: String     // URL or workspace identifier
        let error: String?          // localised error description, nil if not captured
        let attemptedAt: Date
    }

    /// Append a `SendFailureRecord` to `.send_failures.json` inside
    /// the current session directory. Atomic write — reads existing
    /// JSON array (or starts fresh on missing/malformed), appends,
    /// writes back. Hidden filename so it doesn't appear in History
    /// row contents.
    ///
    /// Failure modes silently log but don't propagate — losing the
    /// sidecar on a write error is fine; the toast + os_log already
    /// surfaced the original issue.
    private func recordAutoSendFailure(
        integration: String,
        kind: String,
        destination: String,
        error: String?
    ) {
        guard let directory = sessionDirectory else { return }
        let sidecarURL = directory.appendingPathComponent(".send_failures.json")
        var records: [SendFailureRecord] = []
        if let existing = try? Data(contentsOf: sidecarURL),
           let decoded = try? JSONDecoder.daisySendFailureDecoder.decode([SendFailureRecord].self, from: existing) {
            records = decoded
        }
        records.append(SendFailureRecord(
            integration: integration,
            kind: kind,
            destination: destination,
            error: error,
            attemptedAt: Date()
        ))
        do {
            let data = try JSONEncoder.daisySendFailureEncoder.encode(records)
            try data.write(to: sidecarURL, options: [.atomic])
            log.info("Wrote .send_failures.json (\(records.count, privacy: .public) record(s))")
        } catch {
            log.error("Failed to write .send_failures.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Folder allow-list check used by both Notion and MCP auto-
    /// send paths. Empty allow-list means "every folder" — the
    /// simple default. Non-empty restricts to exactly those slugs.
    nonisolated static func folderAllowed(_ slug: String, allowed: Set<String>) -> Bool {
        allowed.isEmpty || allowed.contains(slug)
    }

    // MARK: - Session snapshots / export

    /// Public companion to `assembleStoredSession` — call sites
    /// (the Send-to popover, the toolbar) need a StoredSession to
    /// hand to MCPDispatcher when the session is still active and
    /// hasn't yet been picked up by SessionStore. Returns a
    /// best-effort snapshot built from current in-memory state.
    func snapshotStoredSession() -> StoredSession {
        let directory = sessionDirectory ?? URL(fileURLWithPath: "/tmp")
        return Self.makeStoredSession(
            id: directory.lastPathComponent,
            directory: directory,
            title: title,
            startedAt: startedAt ?? Date(),
            elapsedSec: Int(elapsed.rounded()),
            locale: localeIdentifier,
            segments: segments,
            summary: summarizer.lastSummary,
            folderSlug: folder.slug,
            kind: sessionKind,
            tag: tag,
            systemAudioStatus: systemAudioStatusValue
        )
    }

    /// Stitch the just-finished session's in-memory state into a
    /// `StoredSession` value. Synchronous so it can serve both the
    /// post-`stop` auto-send path (called in async context) and the
    /// snapshot path used by manual Send-to.
    /// Run the voice-polish rewrite with a hard deadline. Returns the
    /// rewritten text, or nil if it failed OR the deadline elapsed first
    /// (caller then keeps the un-polished dictation). Keeps the paste path
    /// bounded regardless of provider latency.
    nonisolated static func polishWithDeadline(text: String, instruction: String, seconds: Double) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let summary = try? await Summarizer.shared.runProbe(
                    transcript: text,
                    title: "Dictation",
                    localeHint: nil,
                    task: .dictationPolish(instruction: instruction)
                )
                guard let polished = summary?.clientFollowUp
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !polished.isEmpty else { return nil }
                // Sanity gate: polish preserves meaning and stays "in the
                // same ballpark" length-wise (the prompt's own words). A
                // result wildly shorter or longer than the input means the
                // model did something else entirely — summarized it, or
                // drafted an invented follow-up letter (the observed
                // Apple-Intelligence failure mode) — and the caller is
                // about to PASTE this over the user's own words. Reject
                // and keep the raw dictation instead. The +40 slack keeps
                // very short dictations from tripping the upper bound.
                let inCount = text.count
                let outCount = polished.count
                guard outCount * 5 >= inCount * 2,          // ≥ 40% of input
                      outCount <= (inCount * 5) / 2 + 40    // ≤ 250% + slack
                else { return nil }
                return polished
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil  // deadline sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Side notes (voice notes layered over a meeting)

    /// Split each CLOSED side-note window into its own session in the
    /// Notes folder as an EXCERPT of the meeting (2026-07-21 model):
    /// COPY the meeting segments overlapping the window (mic + system,
    /// so the note carries the full context, not just the user's voice),
    /// snap the window to those segments' bounds, and slice a matching
    /// audio clip — mic + system mixed into one `microphone.caf` — out of
    /// the meeting's own archive so the note is replayable. The meeting
    /// itself is never cut. Best-effort — a failure here must NEVER affect
    /// the meeting save, so it runs after the meeting's transcript.md is
    /// on disk and swallows its own errors, while the sessions-folder
    /// ticket is still held.
    func writeSideNotes() async {
        let closed = sideNoteWindows.filter { $0.end != nil }
        guard !closed.isEmpty, let meetingDir = sessionDirectory else { return }
        let base = meetingDir.deletingLastPathComponent()   // …/Daisy/Sessions
        let meetingID = meetingDir.lastPathComponent
        let allSegments = segments
        let displayName = settings.userDisplayName
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let fm = FileManager.default
        var created = 0

        // Decode the meeting's own archives ONCE to 16 kHz mono; every
        // note excerpt is a slice of these. Best-effort — a note still
        // saves its text if the audio can't be decoded.
        let micURLs = archivedAudioParts
        let sysURL = systemArchiveURL
        let micSamples: [Float]? = await Task.detached(priority: .utility) {
            AudioArchiveDecoder.decodeToMono16k(urls: micURLs)
        }.value
        let systemSamples: [Float]? = await Task.detached(priority: .utility) {
            guard let sysURL, FileManager.default.fileExists(atPath: sysURL.path) else { return nil }
            return AudioArchiveDecoder.decodeToMono16k(urls: [sysURL])
        }.value

        for window in closed {
            guard let end = window.end else { continue }

            // Meeting segments (mic + system) that fall inside the marked
            // span — the note is a COPY of these, snapped to their bounds.
            let covered = allSegments
                .filter { $0.startedAt >= window.start && $0.startedAt <= end
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.startSec < $1.startSec }
            guard !covered.isEmpty else { continue }

            let noteStart = covered.first!.startedAt
            let noteEnd = covered.last!.startedAt
            let safeStamp = stamp.string(from: noteStart)
                .replacingOccurrences(of: ":", with: "-")
            let noteDir = base.appendingPathComponent(safeStamp, isDirectory: true)
            guard noteDir.lastPathComponent != meetingID,
                  !fm.fileExists(atPath: noteDir.path) else { continue }
            do { try fm.createDirectory(at: noteDir, withIntermediateDirectories: true) }
            catch {
                log.error("Side note dir failed: \(error.localizedDescription, privacy: .public)")
                continue
            }

            // Transcript body: copy each covered segment with its speaker
            // label, so "Me" vs "Remote" survives in the excerpt.
            let body = covered.map { seg -> String in
                let label = seg.speakerLabel(displayName: displayName)
                return "**[\(label)]** " + seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n\n")
            guard !body.isEmpty else { try? fm.removeItem(at: noteDir); continue }

            // Audio excerpt: slice [startSec, endSec] (snapped to the
            // covered segments) from mic + system and mix into one caf.
            let startSec = max(0, covered.map(\.startSec).min() ?? 0)
            let endSec = max(startSec, covered.map { $0.endSec > 0 ? $0.endSec : $0.startSec }.max() ?? startSec)
            let lo = Int((startSec * 16_000).rounded())
            let hi = Int((endSec * 16_000).rounded())
            var hasAudio = false
            if let excerpt = Self.mixExcerpt(mic: micSamples, system: systemSamples, from: lo, to: hi),
               !excerpt.isEmpty {
                let destCaf = noteDir.appendingPathComponent("microphone.caf")
                hasAudio = await Task.detached(priority: .utility) {
                    AudioArchiveDecoder.writeMono16kCAF(samples: excerpt, to: destCaf)
                }.value
            }

            let md = Self.renderSideNoteMarkdown(
                body: body, start: noteStart, end: noteEnd,
                meetingID: meetingID, hasAudio: hasAudio
            )
            do {
                try Data(md.utf8).write(
                    to: noteDir.appendingPathComponent("transcript.md"),
                    options: .atomic
                )
                created += 1
            } catch {
                log.error("Side note write failed: \(error.localizedDescription, privacy: .public)")
                try? fm.removeItem(at: noteDir)
            }
        }

        if created > 0 {
            await SessionStore.shared.refresh()
            let n = created
            ToastCenter.shared.show(
                n == 1
                    ? String(localized: "Saved a side note to Notes.")
                    : String(localized: "Saved \(n) side notes to Notes."),
                style: .success
            )
        }
    }

    /// Slice `[lo, hi)` (16 kHz mono sample indices) out of the meeting's
    /// mic and system sample arrays and MIX them into one clip, so a note
    /// excerpt carries both the user's voice and the meeting audio in a
    /// single replayable track. Each array is sliced from its own start
    /// and clamped to its own length (mic/system decode lengths differ
    /// slightly); the sum is clamped to [-1, 1] to avoid clip artefacts.
    /// Returns nil when neither stream has audio in the window.
    nonisolated static func mixExcerpt(
        mic: [Float]?, system: [Float]?, from lo: Int, to hi: Int
    ) -> [Float]? {
        guard hi > lo else { return nil }
        func slice(_ s: [Float]?) -> ArraySlice<Float>? {
            guard let s else { return nil }
            let a = max(0, min(lo, s.count))
            let b = max(a, min(hi, s.count))
            return a < b ? s[a..<b] : nil
        }
        let m = slice(mic)
        let sy = slice(system)
        let n = max(m?.count ?? 0, sy?.count ?? 0)
        guard n > 0 else { return nil }
        var out = [Float](repeating: 0, count: n)
        if let m { for (i, v) in m.enumerated() { out[i] += v } }
        if let sy { for (i, v) in sy.enumerated() { out[i] += v } }
        for i in out.indices { out[i] = max(-1, min(1, out[i])) }
        return out
    }

    /// Obsidian-shaped transcript.md for a split-out side note. Minimum
    /// frontmatter (title + started) so SessionStore classifies it
    /// `.valid`, plus `daisy_kind: note` (so it surfaces in the Notes tab
    /// by kind, not by folder), a default `daisy_folder: inbox` project
    /// like any other note, and a `daisy_source_meeting` back-link to the
    /// meeting it was captured during.
    nonisolated static func renderSideNoteMarkdown(
        body: String,
        start: Date,
        end: Date,
        meetingID: String,
        hasAudio: Bool
    ) -> String {
        let iso = ISO8601DateFormatter()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let titleDate = df.string(from: start)
        let durSec = Int(max(0, end.timeIntervalSince(start)).rounded())

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"Side note — \(titleDate)\"")
        lines.append("started: \(iso.string(from: start))")
        lines.append("duration_sec: \(durSec)")
        lines.append("daisy_kind: \(SessionKind.note.rawValue)")
        lines.append("daisy_folder: \(SessionFolder.inbox.slug)")
        lines.append("daisy_source_meeting: \(meetingID)")
        lines.append("---")
        lines.append("")
        lines.append("# Side note — \(titleDate)")
        lines.append("")
        lines.append("> " + String(localized: "An excerpt copied from a meeting into its own note."))
        lines.append("")
        lines.append(body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    nonisolated static func makeStoredSession(
        id: String,
        directory: URL,
        title: String,
        startedAt: Date,
        elapsedSec: Int,
        locale: String,
        segments: [TranscriptSegment],
        summary: MeetingSummary?,
        folderSlug: String,
        kind: SessionKind = .recording,
        tag: String = "",
        systemAudioStatus: String? = nil
    ) -> StoredSession {
        let transcriptText = segments
            .map { "\($0.text)" }
            .joined(separator: " ")
        let preview = String(transcriptText.prefix(220))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system_audio.caf")
        // Read centroid IDs from the sidecar speakers.json if it
        // exists — same path SessionStore.refresh uses. Lets the
        // "session only" UI flag in SessionDetailView work for
        // sessions surfaced through this in-memory builder (post-
        // stop MCP auto-send and the manual Send-to snapshot path).
        // Empty Set is fine when the file is absent or unreadable;
        // SessionDetailView treats missing == "all session-only".
        let centroidIDs: Set<String> = {
            let url = directory.appendingPathComponent("speakers.json")
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(SpeakerCentroidsFile.self, from: data) else {
                return []
            }
            return Set(file.centroids.keys)
        }()
        return StoredSession(
            id: id,
            directoryURL: directory,
            title: title,
            startedAt: startedAt,
            durationSec: elapsedSec,
            locale: locale,
            transcriptPreview: preview,
            transcriptText: transcriptText,
            hasMicAudio: FileManager.default.fileExists(atPath: micURL.path),
            hasSystemAudio: FileManager.default.fileExists(atPath: systemURL.path),
            screenshotURLs: [],
            summary: summary,
            transcriptURL: FileManager.default.fileExists(atPath: transcriptURL.path) ? transcriptURL : nil,
            folderSlug: folderSlug,
            kind: kind,
            tag: tag,
            meetingAttendees: [],
            // In-memory builder (post-stop MCP auto-send + manual
            // Send-to snapshot) — the bound calendar event title +
            // attendees/emails are available off the live
            // RecordingSession, but the function is `static` and
            // doesn't carry them through. Passing empty/nil is the
            // safe default; SessionStore.refresh will re-read
            // frontmatter on the next library scan and pick up the
            // event metadata from disk.
            meetingAttendeeEmails: [],
            linkedEventTitle: nil,
            speakerMap: [:],
            speakerCentroidIDs: centroidIDs,
            systemAudioStatus: systemAudioStatus
        )
    }

    /// Helper: file exists AND has non-zero size. Empty .caf files
    /// can be left behind if AVAudioEngine started its writer but
    /// never received any input frames.
    private func fileExistsNonEmpty(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 1024  // anything below ~1 KB is just CAF headers
    }

    /// Snapshot used by Notion / Claude exporters.
    func exportData() -> MeetingExportData {
        let segmentTexts = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "[\($0.source.displayLabel)] \($0.text)" }

        // Group into ≤1500-char chunks for Notion's 2000-char block limit.
        var chunks: [String] = []
        var current = ""
        for text in segmentTexts {
            if current.count + text.count + 2 > 1500 {
                if !current.isEmpty { chunks.append(current) }
                current = text
            } else {
                current = current.isEmpty ? text : "\(current)\n\n\(text)"
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return MeetingExportData(
            title: title,
            summary: summarizer.lastSummary,
            transcriptChunks: chunks,
            durationSeconds: Int(elapsed),
            locale: localeIdentifier,
            startedAt: startedAt
        )
    }
}
