//
//  Transcriber.swift
//  Daisy
//
//  Whisper-backed live transcriber with chunked-streaming commit.
//
//  Pipeline:
//    1. Consume AudioChunk stream from the recorder.
//    2. Resample each chunk to 16 kHz mono Float32 (Whisper format).
//    3. Periodically re-transcribe the rolling tail window via the shared
//       WhisperEngine.
//    4. Promote segments that fall outside the live window's trailing
//       refine zone into the immutable `committedSegments` list — those
//       are frozen, the UI stops jittering on them.
//    5. On stop, run a final full-buffer pass that supersedes everything
//       (final segmentation is the most accurate Whisper can produce).
//
//  Everything runs on-device via WhisperKit CoreML.
//

import Foundation
import AVFoundation
import Observation
import os

/// Where the audio that produced a segment came from.
enum SegmentSource: String, Sendable, Codable, Equatable {
    case microphone
    case systemAudio

    var displayLabel: String {
        switch self {
        case .microphone: return "you"
        case .systemAudio: return "system"
        }
    }
}

/// One utterance in the live transcript.
struct TranscriptSegment: Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    var text: String
    var isFinal: Bool
    var source: SegmentSource = .microphone
    /// Diarization label inside the same `source` stream — e.g. "A",
    /// "B", "C". `nil` while diarization is still running or if it
    /// failed. UI presents this as "Remote A" / "Remote B" for
    /// system-source segments and "Me" for microphone (we assume one
    /// speaker on the mic side).
    var speakerId: String? = nil
    /// Absolute end time in seconds since the session started. Used by the
    /// commit logic to decide when a pending segment is old enough to
    /// promote to committed. Not displayed.
    var endSec: Double = 0
    /// Absolute start time in seconds since the session started. Used
    /// by diarization merge to do IoU overlap with speaker spans.
    var startSec: Double = 0

    /// Human-facing speaker label combining the source stream with
    /// the diarized speaker id. Examples:
    ///   • mic, no diarization      → "Me"
    ///   • system, no diarization   → "Remote"
    ///   • system, speaker "A"      → "Remote A"
    ///   • system, low IoU (nil)    → "Remote ?"
    var speakerLabel: String { speakerLabel(displayName: nil) }

    /// Speaker label with an optional override for the user's own
    /// voice. Pass the configured `AppSettings.userDisplayName` to
    /// substitute `"Me"` with the real name (e.g. `[Egor]` instead
    /// of `[Me]`); pass nil/empty to keep the legacy generic label.
    /// System-source labels are unaffected — that's the remote
    /// party's voice, not the user's.
    func speakerLabel(displayName: String?) -> String {
        switch source {
        case .microphone:
            // With mic-side diarization enabled (Settings →
            // Transcription) we emit per-cluster labels here too;
            // otherwise the historical single-speaker "Me" label
            // applies. The user can rename "Speaker A → Alex" via
            // the Detail-view speaker map, same path that exists for
            // system-source speakers.
            if let id = speakerId { return "Speaker \(id)" }
            let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Me" : trimmed
        case .systemAudio:
            if let id = speakerId { return "Remote \(id)" }
            return "Remote"
        }
    }
}

@Observable
@MainActor
final class Transcriber {
    // MARK: - Observable

    /// Merged committed + pending segments, sorted by start time. Reads
    /// of this property re-evaluate when either list changes.
    var segments: [TranscriptSegment] {
        (committedSegments + pendingSegments)
            .sorted(by: { $0.startedAt < $1.startedAt })
    }
    private(set) var isRunning = false
    private(set) var lastError: String?
    var localeIdentifier: String

    let source: SegmentSource

    // MARK: - Internal segment storage

    /// Frozen segments — Whisper won't be asked to revisit these.
    private var committedSegments: [TranscriptSegment] = []
    /// Latest pass's segments inside the active refine window.
    private var pendingSegments: [TranscriptSegment] = []
    /// Greatest end-time so far promoted to committed. Skip overlaps.
    private var committedThroughSec: Double = 0

    // MARK: - Audio buffer
    //
    // `allSamples` is a rolling buffer of 16 kHz mono Float32 audio
    // since the last `removeFirst`-trim. We keep at most
    // `bufferedSamplesCap` samples in memory; older samples have been
    // dropped (their absolute count tracked in `samplesDropped`).
    //
    // Index translation:
    //   absoluteSampleIndex = samplesDropped + allSamples.firstIndex
    //   bufferIndex          = absoluteSampleIndex - samplesDropped
    //
    // Indices into `allSamples` are LOCAL; we convert via
    // `samplesDropped` whenever we need to compare against
    // `committedThroughSec` (which is in absolute session-time
    // seconds).
    //
    // Pre-1.0.3 the buffer grew unbounded — ~230 MB on a 2-hour
    // session. Capped now at 30 min worth (~115 MB) which is enough
    // window for the live Whisper kick + live diarization to do
    // useful work. Final-transcribe on stop loses the cleanup pass
    // over audio older than 30 min but the live `committedSegments`
    // covering that range are kept intact, so the transcript still
    // covers the whole session.

    /// 30 minutes at 16 kHz mono = 30 * 60 * 16_000 = 28_800_000
    /// samples = ~115 MB as Float32.
    private static let bufferedSamplesCap: Int = 30 * 60 * 16_000
    /// Drop the oldest 5 minutes in one batch when the cap is hit —
    /// avoids per-buffer `removeFirst` churn (that would be O(n)
    /// every ingest call once we hit the cap).
    private static let trimBatchSamples: Int = 5 * 60 * 16_000

    /// Absolute count of samples dropped from the head of
    /// `allSamples` since the start of the session. Added to any
    /// local index to recover the absolute sample position.
    private var samplesDropped: Int = 0

    private var converter: AudioConverter?
    private var allSamples: [Float] = []

    // MARK: - Tasks / timers

    private var consumerTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var transcribeTask: Task<Void, Never>?

    /// Live diarization task. Only spawned for `.systemAudio`
    /// transcribers — mic is always "Me", no clustering needed.
    /// Runs on a coarser cadence than `transcribeTask` (every
    /// ~15s of new audio) so we don't burn the Neural Engine
    /// re-clustering the same speakers every 2 seconds.
    private var diarizeTask: Task<Void, Never>?
    /// Audio-clock seconds at which the last live diarization run
    /// kicked off. `kickLiveDiarize` skips if we're inside the
    /// minimum interval. Reset on `reset()`.
    private var lastDiarizeSec: Double = 0
    /// How much new audio must accumulate between live
    /// diarization runs. 15s balances label freshness against
    /// the cost of re-clustering on a growing buffer; final
    /// pass on stop is still authoritative.
    private let liveDiarizeIntervalSec: Double = 15.0

    /// Per-cluster centroid embeddings from the most recent
    /// diarization pass — keyed by the same A/B/C labels used in
    /// `TranscriptSegment.speakerId`. Set by `runFinalTranscribe`,
    /// consumed by `RecordingSession.stop()` to write the
    /// `speakers.json` sidecar + match against `SpeakerProfileStore`.
    /// Empty for `.microphone` transcribers (no diarization runs).
    private(set) var speakerCentroids: [String: [Float]] = [:]

    private var sessionStartedAt: Date?
    private var bucketIDs: [Int: UUID] = [:]

    /// Language Whisper will use for every subsequent decode once we
    /// see enough committed text to confidently identify it via
    /// `LanguageDetector` (NLLanguageRecognizer). Stays nil for the
    /// first few seconds of every session, then snaps to a 2-letter
    /// ISO code and stays there.
    ///
    /// Why this exists: with `language: nil` Whisper auto-detects
    /// per chunk, and on noisy / silent chunks it sometimes drifts
    /// — an English meeting suddenly emits "ご視聴ありがとうござ
    /// いました" because a moment of silence got classified as
    /// Japanese. Pinning the language after we know what it is
    /// kills that class of hallucination outright.
    ///
    /// Only used when the user picked "Auto-detect" in Settings
    /// (`localeIdentifier == "auto"`). If they pinned a language
    /// explicitly we honour that and never touch this field.
    private var lockedLanguage: String?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Transcriber")

    // MARK: - Tuning constants

    private let liveIntervalSec: Double = 2.0
    private let liveWindowSec: Double = 30.0
    /// A segment is promoted to "committed" once its end time falls more
    /// than this many seconds before the trailing edge of the rolling
    /// window. Whisper still has refinement room for younger segments.
    private let commitMarginSec: Double = 10.0

    // MARK: - Init

    init(localeIdentifier: String = "auto",
         source: SegmentSource = .microphone,
         diarize: Bool? = nil) {
        self.localeIdentifier = localeIdentifier
        self.source = source
        // Default: diarize iff system-audio (the historical
        // behaviour). Callers can override for mic-side diarization
        // gated on `settings.diarizeMicrophone`.
        self.diarizationEnabled = diarize ?? (source == .systemAudio)
    }

    /// Whether this Transcriber runs Pyannote diarization passes
    /// (live + final). True by default for system-audio source,
    /// false for microphone unless explicitly enabled.
    private let diarizationEnabled: Bool

    // MARK: - Lifecycle

    func start(consuming audio: AsyncStream<AudioChunk>, startedAt: Date) {
        guard !isRunning else { return }
        sessionStartedAt = startedAt
        isRunning = true
        lastError = nil
        committedSegments.removeAll()
        pendingSegments.removeAll()
        committedThroughSec = 0
        allSamples.removeAll()
        samplesDropped = 0
        bucketIDs.removeAll()
        converter = nil

        consumerTask = Task { @MainActor [weak self] in
            for await chunk in audio {
                guard let strong = self else { break }
                strong.ingest(chunk)
            }
        }

        liveTimer = Timer.scheduledTimer(withTimeInterval: liveIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strong = self else { return }
                strong.kickLiveTranscribe()
            }
        }
    }

    /// Soft pause. Kill the live re-transcribe timer so no rolling
    /// Whisper passes run while we're paused — but keep the
    /// consumerTask alive (no audio is flowing anyway because the
    /// upstream capture is paused), keep accumulated segments
    /// visible, keep `isRunning == true` so the rest of the app
    /// reads us as "still in a session".
    func pause() {
        guard isRunning else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        // Wait out any in-flight transcribe in a detached task so
        // we don't block the UI. If it finishes after we resume,
        // its result will land on the same segment maps.
    }

    /// Re-arm the live re-transcribe timer.
    func resume() {
        guard isRunning, liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: liveIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strong = self else { return }
                strong.kickLiveTranscribe()
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        consumerTask?.cancel()
        consumerTask = nil

        await transcribeTask?.value
        transcribeTask = nil

        // Wait for any in-flight live diarization pass — without
        // this it would race with `runFinalTranscribe()` and could
        // overwrite final speaker labels with stale live ones.
        await diarizeTask?.value
        diarizeTask = nil

        await runFinalTranscribe()
        isRunning = false
    }

    func reset() {
        liveTimer?.invalidate()
        liveTimer = nil
        consumerTask?.cancel()
        consumerTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        diarizeTask?.cancel()
        diarizeTask = nil
        lastDiarizeSec = 0
        committedSegments.removeAll()
        pendingSegments.removeAll()
        committedThroughSec = 0
        allSamples.removeAll()
        samplesDropped = 0
        bucketIDs.removeAll()
        speakerCentroids.removeAll()
        converter = nil
        isRunning = false
        lastError = nil
        sessionStartedAt = nil
        lockedLanguage = nil
    }

    // MARK: - Audio ingestion

    private func ingest(_ chunk: AudioChunk) {
        if converter == nil {
            converter = AudioConverter(inputFormat: chunk.pcm.format)
        }
        guard let conv = converter,
              let samples = conv.convert(chunk.pcm),
              !samples.isEmpty else { return }
        allSamples.append(contentsOf: samples)

        // Cap rolling buffer at 30 min. When exceeded, drop the
        // oldest 5 min in one O(n) batch — better than running
        // `removeFirst(N)` per ingest call once we hit the cap.
        // Older samples are gone from memory; their committed
        // transcript segments stay in `committedSegments` so the
        // user-facing transcript is unaffected.
        if allSamples.count > Self.bufferedSamplesCap {
            let toDrop = min(Self.trimBatchSamples, allSamples.count)
            allSamples.removeFirst(toDrop)
            samplesDropped += toDrop
            log.info("Transcriber rolling buffer trimmed: dropped \(toDrop, privacy: .public) samples (total dropped: \(self.samplesDropped, privacy: .public))")
        }
    }

    // MARK: - Live (chunked) transcribe

    private func kickLiveTranscribe() {
        guard isRunning, transcribeTask == nil, !allSamples.isEmpty else { return }

        // Slice the rolling 30 s tail, but skip audio we've already
        // committed — no point re-transcribing settled text.
        //
        // All `committedThroughSec`-derived offsets are ABSOLUTE
        // (session-time relative); convert to local buffer indices
        // by subtracting `samplesDropped`.
        let windowSampleCount = Int(liveWindowSec * 16_000)
        let committedAbsolute = Int(committedThroughSec * 16_000)
        let latestAbsolute = samplesDropped + allSamples.count
        let earliestAbsolute = max(committedAbsolute, latestAbsolute - windowSampleCount)
        // Clamp to current buffer bounds: anything older than the
        // buffer head has been trimmed, so the floor is `samplesDropped`.
        let earliestAbsoluteClamped = max(samplesDropped, earliestAbsolute)
        let clampedOffset = max(0, min(allSamples.count, earliestAbsoluteClamped - samplesDropped))

        guard allSamples.count > clampedOffset else { return }
        let samples = Array(allSamples[clampedOffset..<allSamples.count])
        let windowStartSec = Double(samplesDropped + clampedOffset) / 16_000.0
        let windowEndSec = Double(latestAbsolute) / 16_000.0
        let lang = languageHint

        transcribeTask = Task { @MainActor [weak self] in
            do {
                let result = try await WhisperEngine.shared.transcribe(
                    samples: samples,
                    language: lang
                )
                if let strong = self {
                    strong.applyLivePass(
                        result,
                        windowStartSec: windowStartSec,
                        windowEndSec: windowEndSec
                    )
                }
            } catch {
                if let strong = self {
                    strong.log.error("Live transcribe failed: \(error.localizedDescription, privacy: .public)")
                    strong.lastError = error.localizedDescription
                }
            }
            if let strong = self {
                strong.transcribeTask = nil
            }
        }
    }

    private func applyLivePass(_ result: [WhisperSegment],
                               windowStartSec: Double,
                               windowEndSec: Double) {
        guard let started = sessionStartedAt else { return }

        let commitCutoff = windowEndSec - commitMarginSec
        var newCommitted: [TranscriptSegment] = []
        var newPending: [TranscriptSegment] = []

        for ws in result {
            let trimmed = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let absStart = windowStartSec + ws.start
            let absEnd = windowStartSec + ws.end

            // Skip segments that are entirely older than what's already
            // committed (defensive — shouldn't happen given our offset).
            if absEnd <= committedThroughSec { continue }

            // Bucket at 100 ms resolution — coarser keys cause two
            // distinct short utterances ("yes." then "ok.") to share
            // a UUID, after which SwiftUI's ForEach silently drops
            // one of them.
            let bucket = Int(absStart * 10)
            let id = bucketIDs[bucket] ?? UUID()
            bucketIDs[bucket] = id

            let candidate = TranscriptSegment(
                id: id,
                startedAt: started.addingTimeInterval(absStart),
                text: trimmed,
                isFinal: false,
                source: source,
                endSec: absEnd,
                startSec: absStart
            )

            if absEnd <= commitCutoff {
                var frozen = candidate
                frozen.isFinal = true
                newCommitted.append(frozen)
            } else {
                newPending.append(candidate)
            }
        }

        if !newCommitted.isEmpty {
            committedSegments.append(contentsOf: newCommitted)
            committedThroughSec = max(committedThroughSec,
                                      newCommitted.map(\.endSec).max() ?? 0)
            // Drop any old pending whose bucket is now covered.
            pendingSegments.removeAll { $0.endSec <= committedThroughSec }
            updateLockedLanguageIfPossible()
        }
        pendingSegments = newPending

        // Live diarization tick — only for system-audio transcribers,
        // and only every ~15s of accumulated audio. Mic source skips
        // entirely (single speaker "Me", no clustering needed).
        kickLiveDiarizeIfDue(currentAudioSec: windowEndSec)
    }

    // MARK: - Live diarization
    //
    // Periodic in-session pass that gives users mid-meeting visibility
    // into who's speaking. Tradeoffs:
    //
    //   • Cadence: every 15s, not per-Whisper-pass. Per-pass would
    //     run diarization every 2s on an ever-growing buffer — O(n²)
    //     on long meetings, no perceptible UX gain over 15s.
    //   • Scope: only `.systemAudio`. Mic side is always "Me".
    //   • Label stability: once a committed segment receives a
    //     speakerId, we DON'T override it on later runs even if the
    //     clustering shifts. Prevents the "Alex turned into Bob" jolt
    //     when FluidAudio re-clusters on a fresh audio length.
    //   • Final pass on stop is unchanged — full re-merge with fresh
    //     IDs, authoritative output for transcript.md.

    private func kickLiveDiarizeIfDue(currentAudioSec: Double) {
        guard diarizationEnabled else { return }
        guard diarizeTask == nil else { return }
        // First pass needs ~10s of audio to cluster anything useful;
        // skip earlier ticks so we don't waste a run on 2 seconds
        // of "hello".
        guard currentAudioSec >= 10 else { return }
        guard currentAudioSec - lastDiarizeSec >= liveDiarizeIntervalSec else { return }

        lastDiarizeSec = currentAudioSec
        let snapshotSamples = allSamples

        diarizeTask = Task { @MainActor [weak self] in
            let spans = await DiarizationEngine.shared.diarize(samples: snapshotSamples)
            guard let strong = self else { return }
            strong.applyLiveDiarization(spans: spans)
            strong.diarizeTask = nil
        }
    }

    /// Apply diarized spans to committed segments. Skips any
    /// segment that already has a `speakerId` — label stability >
    /// label freshness.
    private func applyLiveDiarization(spans: [DiarizedSpan]) {
        guard !spans.isEmpty else { return }
        committedSegments = committedSegments.map { seg in
            guard seg.speakerId == nil else { return seg }
            var copy = seg
            let segLen = seg.endSec - seg.startSec
            guard segLen > 0 else { return copy }

            var best: (id: String, ratio: Double)?
            for span in spans {
                let overlapStart = max(seg.startSec, span.startSec)
                let overlapEnd = min(seg.endSec, span.endSec)
                guard overlapEnd > overlapStart else { continue }
                let ratio = (overlapEnd - overlapStart) / segLen
                if best == nil || ratio > best!.ratio {
                    best = (span.speakerId, ratio)
                }
            }
            if let best, best.ratio >= 0.30 {
                copy.speakerId = best.id
            }
            return copy
        }
    }

    // MARK: - Final transcribe on stop

    private func runFinalTranscribe() async {
        guard !allSamples.isEmpty, let started = sessionStartedAt else { return }
        let samples = allSamples
        let lang = languageHint

        // Run Whisper + diarization in parallel — both are CoreML on
        // the Neural Engine, but Whisper hogs the encoder and the
        // diarizer is much lighter (~15-25% of Whisper runtime), so
        // overlapping them is essentially free.
        async let whisperResult = WhisperEngine.shared.transcribe(
            samples: samples,
            language: lang
        )
        // Diarization is opt-in for the mic source (Settings →
        // Transcription → "Diarize microphone too") and on-by-
        // default for system audio. Use the FULL diarization output
        // (spans + centroids) so RecordingSession can fingerprint-
        // match this session's speakers against the SpeakerProfileStore.
        async let diarizationOutput: DiarizationOutput =
            diarizationEnabled
                ? DiarizationEngine.shared.diarizeFull(samples: samples)
                : DiarizationOutput(spans: [], centroids: [:])

        do {
            let result = try await whisperResult
            let output = await diarizationOutput

            // The final pass covers the audio currently in
            // `allSamples`. If the buffer was trimmed on a long
            // session (>30 min), `samples[0]` corresponds to
            // session-time `finalRangeStart`, NOT zero. We keep
            // older committed segments — they were built up by
            // live passes before trimming — and replace only the
            // overlapping range with this final pass's output.
            let finalRangeStart = Double(samplesDropped) / 16_000.0

            if samplesDropped > 0 {
                // Long session — preserve earlier text from live
                // commits, drop only segments in the final-pass
                // range so they can be replaced with cleaner output.
                committedSegments = committedSegments.filter { $0.endSec <= finalRangeStart }
                pendingSegments.removeAll()
                bucketIDs.removeAll()
                committedThroughSec = finalRangeStart
                log.info("Final pass: long session (>\(Int(finalRangeStart), privacy: .public)s) — preserved \(self.committedSegments.count, privacy: .public) earlier live segments")
            } else {
                // Short session — final pass is authoritative for
                // the whole transcript. Pre-1.0.3 behaviour.
                committedSegments.removeAll()
                pendingSegments.removeAll()
                bucketIDs.removeAll()
                committedThroughSec = 0
            }

            // Whisper returns segment timestamps relative to
            // samples[0]. Offset by `finalRangeStart` to get
            // session-absolute times.
            var fresh: [TranscriptSegment] = []
            for ws in result {
                let trimmed = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let absStart = ws.start + finalRangeStart
                let absEnd = ws.end + finalRangeStart
                fresh.append(TranscriptSegment(
                    id: UUID(),
                    startedAt: started.addingTimeInterval(absStart),
                    text: trimmed,
                    isFinal: true,
                    source: source,
                    speakerId: nil,
                    endSec: absEnd,
                    startSec: absStart
                ))
            }
            log.info("Final pass: \(fresh.count) segments from Whisper, \(output.spans.count) speaker spans from FluidAudio (\(output.centroids.count) centroids)")

            // Attach speaker labels via max-IoU overlap. Diarization
            // spans are also relative to samples[0]; offset them too.
            let offsetSpans: [DiarizedSpan] = output.spans.map { span in
                DiarizedSpan(
                    speakerId: span.speakerId,
                    startSec: span.startSec + finalRangeStart,
                    endSec: span.endSec + finalRangeStart
                )
            }
            let mergedFresh = DiarizationEngine.mergeBySpeaker(
                segments: fresh,
                diarization: offsetSpans
            )
            // Append fresh on top of any preserved earlier segments.
            committedSegments.append(contentsOf: mergedFresh)
            committedSegments.sort { $0.startSec < $1.startSec }
            committedThroughSec = committedSegments.map(\.endSec).max() ?? 0
            // Stash centroids so RecordingSession.stop() can write
            // the speakers.json sidecar + match against profiles.
            speakerCentroids = output.centroids
        } catch {
            log.error("Final transcribe failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Locale

    /// Whisper takes two-letter ISO codes (en, ru, …) or nil for auto.
    ///
    /// Resolution order:
    ///   1. Explicit user choice in Settings (anything that isn't
    ///      "auto") — always wins.
    ///   2. Auto-detect WITH a snapped `lockedLanguage` — feed the
    ///      locked code to Whisper so it stops auto-detecting per
    ///      chunk and stops drifting on noise.
    ///   3. Auto-detect, not yet locked — return nil so Whisper picks
    ///      a language per chunk while we wait for enough committed
    ///      text to lock on.
    private var languageHint: String? {
        let prefix = localeIdentifier
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if let prefix, prefix != "auto" { return prefix }
        return lockedLanguage
    }

    /// Try to snap `lockedLanguage` once we have enough committed
    /// text to be sure. Called from `applyLivePass` after each
    /// committed batch. Idempotent — once locked, stays locked for
    /// the session.
    private func updateLockedLanguageIfPossible() {
        guard lockedLanguage == nil else { return }
        // Only act when the user is on Auto-detect — if they pinned
        // a language explicitly, no locking needed.
        let isAuto = (
            localeIdentifier.split(separator: "-").first.map(String.init)?.lowercased() ?? "auto"
        ) == "auto"
        guard isAuto else { return }
        // Need a meaningful amount of confirmed text before we trust
        // the detector. 3 committed segments + ~120 chars is the
        // sweet spot in QA — earlier than that and pure-noise leaks
        // ("so", "はい") through filter (1)–(3) can still bias the
        // language detection.
        guard committedSegments.count >= 3 else { return }
        let text = committedSegments
            .map(\.text)
            .joined(separator: " ")
        guard text.count >= 120 else { return }
        if let detected = LanguageDetector.detect(text) {
            lockedLanguage = detected
            log.info("Locked transcription language to \(detected, privacy: .public) after \(self.committedSegments.count, privacy: .public) committed segments")
        }
    }

    // MARK: - Locale catalog (exposed for UI)

    static let availableLocales: [(id: String, label: String)] = [
        ("auto",  "Auto-detect"),
        ("en",    "English"),
        ("ru",    "Русский"),
        ("es",    "Español"),
        ("de",    "Deutsch"),
        ("fr",    "Français"),
        ("ja",    "日本語"),
        ("zh",    "中文"),
    ]
}
