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
            let models = try await DiarizerModels.downloadIfNeeded()
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
    func diarize(samples: [Float]) async -> [DiarizedSpan] {
        // Skip very short clips — diarization needs at least a few
        // seconds to cluster meaningfully.
        guard samples.count > 16_000 * 3 else { return [] }

        #if canImport(FluidAudio)
        if manager == nil { await ensureLoaded() }
        guard let manager else { return [] }

        do {
            // First arg is UNLABELED in FluidAudio. The call is
            // synchronous-throws, not async.
            let result = try manager.performCompleteDiarization(samples)
            // FluidAudio gives us `speakerId` like "Speaker_1",
            // "Speaker_3" with gaps after clustering. We relabel to
            // A/B/C in first-appearance order so the user sees clean
            // labels.
            let relabelled = Self.relabel(result.segments)
            return relabelled.map { seg in
                DiarizedSpan(
                    speakerId: seg.label,
                    startSec: Double(seg.start),
                    endSec: Double(seg.end)
                )
            }
        } catch {
            log.error("Diarize failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        #else
        return []
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

    /// FluidAudio's raw speaker ids look like "Speaker_1", "Speaker_3"
    /// (with gaps after clustering). We relabel in first-appearance
    /// order so the user sees "A", "B", "C" — matches how a human
    /// would call them.
    #if canImport(FluidAudio)
    private static func relabel(_ raw: [TimedSpeakerSegment]) -> [(label: String, start: Float, end: Float)] {
        let sorted = raw.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var map: [String: String] = [:]
        var next = 0
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var result: [(String, Float, Float)] = []
        for seg in sorted {
            if map[seg.speakerId] == nil {
                let idx = alphabet.index(alphabet.startIndex, offsetBy: min(next, 25))
                map[seg.speakerId] = String(alphabet[idx])
                next += 1
            }
            let label = map[seg.speakerId] ?? "?"
            result.append((label, seg.startTimeSeconds, seg.endTimeSeconds))
        }
        return result
    }
    #endif
}
