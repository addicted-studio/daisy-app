//
//  DiarizationEngine.swift
//  Daisy
//
//  Thin Daisy-side wrapper around FluidAudio's speaker diarizer.
//  Runs fully on-device on the Apple Neural Engine, same 16 kHz mono
//  Float32 audio contract that WhisperEngine consumes.
//
//  We chose FluidAudio over Argmax's OSS SpeakerKit (per the May 2026
//  research pass) because:
//    • Live project, 50+ releases, Apache 2.0 (App-Store-safe).
//    • Ships pyannote-segmentation + a Sortformer-style clustering
//      pipeline on CoreML / ANE.
//    • Real-time factor ~60× on M1 — fits inside our "no more than
//      2× of Whisper" runtime budget for the post-process pass.
//    • Same input format as Whisper, so we feed it the buffer we
//      already accumulated.
//
//  SPM dependency:
//    https://github.com/FluidInference/FluidAudio  (FluidAudio library
//    only — fluidaudiocli executable is unused).
//
//  Wiring: `Transcriber.runFinalTranscribe()` calls
//  `DiarizationEngine.shared.diarize(samples:)` once the final
//  Whisper pass returns, then `mergeBySpeaker(segments:diarization:)`
//  assigns `speakerId` to each `TranscriptSegment` by max-IoU overlap.
//
//  API note (May 2026, FluidAudio 0.14.x): loading is two-step —
//  `try await DiarizerModels.downloadIfNeeded()` returns a `DiarizerModels`
//  bundle (one-time CoreML download, cached on disk); we hand that to
//  `DiarizerManager.initialize(models:)`. The diarization entrypoint
//  itself is *synchronous throws*, NOT async — the first audio param
//  is unlabeled.
//

import Foundation
import os

#if canImport(FluidAudio)
import FluidAudio
#endif

/// One span of audio attributed to a single speaker.
struct DiarizedSpan: Sendable, Equatable {
    let speakerId: String   // "A", "B", "C", …
    let startSec: Double
    let endSec: Double
}

/// Full output of a diarization run — spans + per-cluster centroid
/// embeddings keyed by the same A/B/C labels used in `DiarizedSpan`.
/// Centroids are the average 256-d embedding across all utterances
/// of one speaker, L2-normalized. Used by `SpeakerProfileStore`
/// for cross-session voice fingerprinting.
struct DiarizationOutput: Sendable {
    let spans: [DiarizedSpan]
    let centroids: [String: [Float]]
}

@MainActor
final class DiarizationEngine {
    static let shared = DiarizationEngine()

    /// Whether FluidAudio is linked + initialised. When false, all
    /// `diarize` calls return an empty array — transcripts still ship,
    /// just without speaker labels.
    private(set) var isAvailable: Bool = false

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Diarizer")

    #if canImport(FluidAudio)
    /// Holds the FluidAudio diarizer once it finishes loading. The
    /// load is async (downloads / decompresses the CoreML models on
    /// first run) so we lazy-initialise it on first call.
    private var manager: DiarizerManager?
    /// Cached model bundle so a per-session "hinted" manager (pinned to a
    /// known speaker count) can be spun up without re-downloading. Set in
    /// `ensureLoaded`; read only on the opt-in attendee-count-hint path.
    private var models: DiarizerModels?
    #endif

    private init() {}

    /// Force the model bundle to load. Safe to call multiple times.
    /// Idempotent.
    func ensureLoaded() async {
        #if canImport(FluidAudio)
        guard manager == nil else { return }
        do {
            // One-time download of the CoreML diarization bundle from
            // HuggingFace (cached in app container after first run).
            // Offline-first (2026-06-08): with FluidAudio's network
            // hard-blocked by `FluidAudioNetworkGuard`, a complete cache
            // loads with NO network possible; a missing/incomplete cache
            // throws OfflineError and we retry inside an explicit,
            // logged download window.
            let models: DiarizerModels
            do {
                models = try await DiarizerModels.downloadIfNeeded()
            } catch let error where FluidAudioNetworkGuard.isOfflineRejection(error) {
                models = try await FluidAudioNetworkGuard.withDownloadsAllowed("diarizer models") {
                    try await DiarizerModels.downloadIfNeeded()
                }
            }
            self.models = models   // cache for the optional speaker-count-hint path
            // Default config — numClusters = -1 means "auto-detect
            // number of speakers" (typically 2-4 for our use case).
            // Tune `clusteringThreshold` upward if it over-splits
            // (one speaker getting tagged as two).
            let config = DiarizerConfig(
                clusteringThreshold: 0.7,
                minSpeechDuration: 1.0,
                minSilenceGap: 0.5,
                numClusters: -1
            )
            let m = DiarizerManager(config: config)
            m.initialize(models: models)
            self.manager = m
            self.isAvailable = true
            log.info("FluidAudio diarizer loaded")
        } catch {
            log.error("Diarizer init failed: \(error.localizedDescription, privacy: .public)")
            self.isAvailable = false
        }
        #else
        self.isAvailable = false
        #endif
    }

    /// Run diarization on a buffer. Returns one span per detected
    /// speaker turn. Empty array if the package isn't linked, the
    /// model failed to load, or the audio is too short.
    ///
    /// Convenience wrapper around `diarizeFull` that discards the
    /// centroids — the live in-session diarization path doesn't need
    /// them, only the post-stop voice-fingerprint pass does.
    func diarize(samples: [Float]) async -> [DiarizedSpan] {
        await diarizeFull(samples: samples).spans
    }

    /// Full diarization with cluster centroids returned alongside
    /// the spans. Called from `Transcriber.runFinalTranscribe()` so
    /// the post-stop pass can match centroids against the
    /// `SpeakerProfileStore` for cross-session "this is Alex"
    /// auto-labelling.
    ///
    /// `centroids` is the AVERAGE of all segment embeddings per
    /// speaker. FluidAudio's `DiarizationResult.speakerDatabase`
    /// sometimes provides this directly; when it doesn't we compute
    /// it ourselves from `segments[i].embedding`.
    func diarizeFull(samples: [Float], numSpeakers: Int? = nil) async -> DiarizationOutput {
        guard samples.count > 16_000 * 3 else {
            return DiarizationOutput(spans: [], centroids: [:])
        }

        #if canImport(FluidAudio)
        if manager == nil { await ensureLoaded() }
        guard let manager else {
            return DiarizationOutput(spans: [], centroids: [:])
        }

        // EXPERIMENTAL speaker-count hint (opt-in, off by default): when a
        // trusted count is supplied (calendar attendees − you), run a
        // throwaway manager pinned to numClusters = count instead of the
        // shared auto-detect (-1) manager. numClusters is a HARD constraint,
        // so a wrong count can hurt — gated in AppSettings. `nil` ⇒ this
        // path is skipped and behaviour is byte-identical to before.
        let activeManager: DiarizerManager
        if let n = numSpeakers, n > 0, let models {
            let hintedConfig = DiarizerConfig(
                clusteringThreshold: 0.7,
                minSpeechDuration: 1.0,
                minSilenceGap: 0.5,
                numClusters: n
            )
            let hinted = DiarizerManager(config: hintedConfig)
            hinted.initialize(models: models)
            activeManager = hinted
            log.info("Diarizing with attendee-count hint: numClusters=\(n, privacy: .public)")
        } else {
            activeManager = manager
        }

        do {
            let result = try activeManager.performCompleteDiarization(samples)
            // 1. Relabel Speaker_1 / Speaker_3 / ... → A / B / C
            //    using first-appearance order. Keep a parallel
            //    mapping from raw → relabelled so we can apply the
            //    same relabel to centroids.
            let labelMap = Self.buildLabelMap(result.segments)

            let spans: [DiarizedSpan] = result.segments
                .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
                .compactMap { seg in
                    guard let label = labelMap[seg.speakerId] else { return nil }
                    return DiarizedSpan(
                        speakerId: label,
                        startSec: Double(seg.startTimeSeconds),
                        endSec: Double(seg.endTimeSeconds)
                    )
                }

            // 2. Compute per-cluster centroids. Average all segment
            //    embeddings sharing the same raw speakerId, then
            //    L2-normalize (so cosine similarity stays well-
            //    defined). FluidAudio's `speakerDatabase` may also
            //    have this — when present we use it directly,
            //    otherwise we compute from per-segment embeddings.
            var centroids: [String: [Float]] = [:]
            if let db = result.speakerDatabase {
                for (rawID, embedding) in db {
                    if let label = labelMap[rawID] {
                        centroids[label] = embedding
                    }
                }
            }
            if centroids.isEmpty {
                centroids = Self.computeCentroids(
                    from: result.segments,
                    labelMap: labelMap
                )
            }

            return DiarizationOutput(spans: spans, centroids: centroids)
        } catch {
            log.error("Diarize failed: \(error.localizedDescription, privacy: .public)")
            return DiarizationOutput(spans: [], centroids: [:])
        }
        #else
        return DiarizationOutput(spans: [], centroids: [:])
        #endif
    }

    /// Extract a single 256-d L2-normalized embedding from an audio
    /// buffer. Used as an escape hatch — currently `diarizeFull`
    /// covers the full session path, but if a future feature needs
    /// to embed a known-speaker clip (e.g. user records 5s of
    /// themselves to enroll a profile manually), this is the
    /// one-shot entrypoint.
    func extractEmbedding(samples: [Float]) async -> [Float]? {
        #if canImport(FluidAudio)
        if manager == nil { await ensureLoaded() }
        guard let manager else { return nil }
        do {
            return try manager.extractSpeakerEmbedding(from: samples)
        } catch {
            log.error("Extract embedding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Merge whisper segments with diarized spans by max-IoU overlap.
    /// If IoU < `confidenceThreshold` we leave `speakerId` at nil so
    /// the UI can render a "?" marker the user can manually fix.
    static func mergeBySpeaker(
        segments: [TranscriptSegment],
        diarization spans: [DiarizedSpan],
        confidenceThreshold: Double = 0.30
    ) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return segments }
        return segments.map { seg in
            var copy = seg
            let segStart = seg.startSec
            let segEnd = seg.endSec
            guard segEnd > segStart else { return copy }
            let segLen = segEnd - segStart

            var best: (id: String, iou: Double)?
            for span in spans {
                let overlapStart = max(segStart, span.startSec)
                let overlapEnd = min(segEnd, span.endSec)
                guard overlapEnd > overlapStart else { continue }
                let overlap = overlapEnd - overlapStart
                // IoU relative to the segment's own length — easier
                // to reason about than the union-based IoU because
                // diarized spans are typically much longer than
                // whisper segments.
                let iou = overlap / segLen
                if best == nil || iou > best!.iou {
                    best = (span.speakerId, iou)
                }
            }

            if let best, best.iou >= confidenceThreshold {
                copy.speakerId = best.id
            }
            return copy
        }
    }

    // MARK: - Relabel speakers to A/B/C

    /// Build a raw-speakerId → "A" / "B" / "C" map in first-
    /// appearance order. Single source of truth — spans + centroids
    /// both reference the same map so their labels stay in sync.
    #if canImport(FluidAudio)
    private static func buildLabelMap(_ raw: [TimedSpeakerSegment]) -> [String: String] {
        let sorted = raw.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var map: [String: String] = [:]
        var next = 0
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for seg in sorted {
            if map[seg.speakerId] == nil {
                let idx = alphabet.index(alphabet.startIndex, offsetBy: min(next, 25))
                map[seg.speakerId] = String(alphabet[idx])
                next += 1
            }
        }
        return map
    }

    /// Compute per-cluster centroids by averaging the per-segment
    /// `embedding` field, then L2-normalizing the result so cosine
    /// similarity stays valid. Used when FluidAudio's
    /// `speakerDatabase` isn't populated (some pipeline configs).
    private static func computeCentroids(
        from segments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for seg in segments {
            guard let label = labelMap[seg.speakerId] else { continue }
            let embedding = seg.embedding
            guard !embedding.isEmpty else { continue }
            if var running = sums[label] {
                for i in 0..<min(running.count, embedding.count) {
                    running[i] += embedding[i]
                }
                sums[label] = running
            } else {
                sums[label] = embedding
            }
            counts[label, default: 0] += 1
        }
        var result: [String: [Float]] = [:]
        for (label, sum) in sums {
            let count = Float(counts[label] ?? 1)
            var avg = sum.map { $0 / count }
            // L2 normalize so cosine sim against profile embeddings
            // (which are themselves L2 normalized) reduces to a
            // dot product — matches what `speakerCosineSimilarity`
            // expects.
            var magnitude: Float = 0
            for v in avg { magnitude += v * v }
            magnitude = sqrtf(magnitude)
            if magnitude > 0 {
                avg = avg.map { $0 / magnitude }
            }
            result[label] = avg
        }
        return result
    }
    #endif
}

#if canImport(FluidAudio)
/// App-wide policy for FluidAudio's network access (2026-06-08).
///
/// FluidAudio 0.15 added `DownloadUtils.enforceOffline`: when true, every
/// download surface throws a typed `OfflineError` instead of touching the
/// network, and a corrupt model cache fails loudly instead of silently
/// re-downloading mid-meeting. Daisy keeps the flag ON for the whole app
/// lifetime — "nothing leaves your Mac" enforced in code, not just
/// promised — and opens short, explicit, logged download windows only
/// when a loader reports its cache is missing/incomplete (first run, or
/// the user enabling a new engine). Loaders use the offline-first shape:
///
///     do { try await load() }
///     catch let e where FluidAudioNetworkGuard.isOfflineRejection(e) {
///         try await FluidAudioNetworkGuard.withDownloadsAllowed("x") {
///             try await load()
///         }
///     }
///
/// Call sites: DiarizationEngine.ensureLoaded (diarizer models),
/// WhisperEngine.ensureVADLoadStarted (Silero VAD), ParakeetEngine
/// .performLoad (Parakeet v3 ASR). Engaged at launch from
/// DaisyAppDelegate.applicationDidFinishLaunching.
@MainActor
enum FluidAudioNetworkGuard {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "FluidAudioNet")
    /// Open download windows, refcounted so overlapping loads (e.g.
    /// diarizer + VAD on first run) don't re-block each other early.
    private static var openWindows = 0

    /// Hard-block FluidAudio's network. Idempotent; called once at launch.
    /// No-op while a download window is open (engage() can't race a
    /// legitimate first-run download).
    static func engage() {
        guard openWindows == 0 else { return }
        DownloadUtils.enforceOffline = true
        log.info("FluidAudio offline enforcement ON — network blocked outside explicit download windows")
    }

    /// Run `body` with downloads temporarily allowed, then re-engage.
    static func withDownloadsAllowed<T>(
        _ operation: String,
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        openWindows += 1
        DownloadUtils.enforceOffline = false
        log.info("FluidAudio download window OPEN: \(operation, privacy: .public)")
        defer {
            openWindows -= 1
            if openWindows == 0 {
                DownloadUtils.enforceOffline = true
                log.info("FluidAudio download window CLOSED: \(operation, privacy: .public) — offline enforcement back on")
            }
        }
        return try await body()
    }

    /// True when `error` is FluidAudio's offline-mode rejection — the
    /// signal that a cache is missing and a download window is needed.
    static func isOfflineRejection(_ error: Error) -> Bool {
        error is DownloadUtils.OfflineError
    }
}
#endif
