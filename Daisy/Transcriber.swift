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
    var speakerLabel: String {
        switch source {
        case .microphone:
            return "Me"
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

    private var converter: AudioConverter?
    private var allSamples: [Float] = []

    // MARK: - Tasks / timers

    private var consumerTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var transcribeTask: Task<Void, Never>?
    private var sessionStartedAt: Date?
    private var bucketIDs: [Int: UUID] = [:]

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Transcriber")

    // MARK: - Tuning constants

    private let liveIntervalSec: Double = 2.0
    private let liveWindowSec: Double = 30.0
    /// A segment is promoted to "committed" once its end time falls more
    /// than this many seconds before the trailing edge of the rolling
    /// window. Whisper still has refinement room for younger segments.
    private let commitMarginSec: Double = 10.0

    // MARK: - Init

    init(localeIdentifier: String = "auto", source: SegmentSource = .microphone) {
        self.localeIdentifier = localeIdentifier
        self.source = source
    }

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

    func stop() async {
        guard isRunning else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        consumerTask?.cancel()
        consumerTask = nil

        await transcribeTask?.value
        transcribeTask = nil

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
        committedSegments.removeAll()
        pendingSegments.removeAll()
        committedThroughSec = 0
        allSamples.removeAll()
        bucketIDs.removeAll()
        converter = nil
        isRunning = false
        lastError = nil
        sessionStartedAt = nil
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
    }

    // MARK: - Live (chunked) transcribe

    private func kickLiveTranscribe() {
        guard isRunning, transcribeTask == nil, !allSamples.isEmpty else { return }

        // Slice the rolling 30 s tail, but skip audio we've already
        // committed — no point re-transcribing settled text.
        let windowSampleCount = Int(liveWindowSec * 16_000)
        let committedSampleOffset = Int(committedThroughSec * 16_000)
        let earliestUsableOffset = max(committedSampleOffset, allSamples.count - windowSampleCount)
        let clampedOffset = max(0, min(allSamples.count, earliestUsableOffset))

        guard allSamples.count > clampedOffset else { return }
        let samples = Array(allSamples[clampedOffset..<allSamples.count])
        let windowStartSec = Double(clampedOffset) / 16_000.0
        let windowEndSec = Double(allSamples.count) / 16_000.0
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
        }
        pendingSegments = newPending
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
        // Mic-side diarization is overkill — assume one speaker.
        // System-side has the actual remote participants.
        async let diarizationResult: [DiarizedSpan] =
            source == .systemAudio
                ? DiarizationEngine.shared.diarize(samples: samples)
                : []

        do {
            let result = try await whisperResult
            let spans = await diarizationResult

            // Final result supersedes everything — wipe + repopulate.
            committedSegments.removeAll()
            pendingSegments.removeAll()
            bucketIDs.removeAll()
            committedThroughSec = 0

            // The final pass is authoritative — no need to keep IDs
            // stable across passes anymore. Fresh UUID per segment
            // means two utterances that round to the same bucket
            // won't share an id and clobber each other in the UI.
            var fresh: [TranscriptSegment] = []
            for ws in result {
                let trimmed = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                fresh.append(TranscriptSegment(
                    id: UUID(),
                    startedAt: started.addingTimeInterval(ws.start),
                    text: trimmed,
                    isFinal: true,
                    source: source,
                    speakerId: nil,
                    endSec: ws.end,
                    startSec: ws.start
                ))
            }
            log.info("Final pass: \(fresh.count) segments from Whisper, \(spans.count) speaker spans from FluidAudio")

            // Attach speaker labels via max-IoU overlap.
            committedSegments = DiarizationEngine.mergeBySpeaker(
                segments: fresh,
                diarization: spans
            )
            committedThroughSec = committedSegments.map(\.endSec).max() ?? 0
        } catch {
            log.error("Final transcribe failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Locale

    /// Whisper takes two-letter ISO codes (en, ru, …) or nil for auto.
    private var languageHint: String? {
        let prefix = localeIdentifier
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if prefix == nil || prefix == "auto" { return nil }
        return prefix
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
