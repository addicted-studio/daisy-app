//
//  WhisperEngine.swift
//  Daisy
//
//  Singleton wrapper around WhisperKit (Argmax). Model download is split
//  from model load so the UI can show real progress. One CoreML instance
//  is shared between the mic + system-audio transcribers; concurrent
//  transcribe requests are serialized via an in-actor semaphore.
//

import Foundation
import Observation
import os
import WhisperKit

@MainActor
@Observable
final class WhisperEngine {
    enum LoadState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading(status: String)
        case ready
        case failed(String)
    }

    /// Catalog of CoreML-converted Whisper models on Argmax's HuggingFace
    /// repo (argmaxinc/whisperkit-coreml). IDs are short suffixes;
    /// WhisperKit prepends "openai_whisper-" internally when resolving
    /// HF folder names.
    ///
    /// `large-v3-v20240930` IS large-v3-turbo — Argmax keeps OpenAI's
    /// release-date naming (turbo was released 2024-09-30). The
    /// `_626MB` variant is mixed-bit quantized to ~626 MB while
    /// retaining ~99% of large-v3 accuracy — Argmax's officially
    /// recommended default for multilingual.
    /// Curated two-model lineup. Removed tiny/base/small/medium and
    /// large-v2 / large-v3-non-turbo to kill paradox-of-choice in
    /// Settings. Most users never benchmark themselves; we pick the
    /// sane defaults for them. Power users who genuinely need other
    /// sizes can be re-enabled via Advanced settings later if there's
    /// demand.
    static let availableModels: [(id: String, label: String, sizeMB: Int)] = [
        ("large-v3-v20240930_626MB", "Standard — fast, multilingual (recommended)",  626),
        ("large-v3-v20240930",       "Highest accuracy — large-v3 turbo, full",     1500),
    ]

    /// First-run default — `large-v3-v20240930_626MB`. 626 MB quantized
    /// turbo: multilingual (incl. RU), ~99% of large-v3 quality, lands
    /// total app footprint in the ~700 MB sweet spot Shadow hits.
    /// Existing installs keep whatever they previously picked.
    static let defaultModelID = "large-v3-v20240930_626MB"
    static let shared = WhisperEngine()

    var modelID: String {
        didSet {
            guard oldValue != modelID else { return }
            UserDefaults.standard.set(modelID, forKey: Self.modelKey)
            Task { await self.reload() }
        }
    }

    private(set) var state: LoadState = .notLoaded
    /// Progress 0.0–1.0 during the .downloading phase. Mirrors the value
    /// from .downloading associated value for binding-friendly UI.
    private(set) var downloadProgress: Double = 0

    @ObservationIgnored
    private var kitBox: WhisperKitBox?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    // In-actor serialization for transcribe — WhisperKit isn't thread-safe
    // for simultaneous transcribes.
    @ObservationIgnored
    private var isBusy = false
    @ObservationIgnored
    private var waiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Whisper")

    private static let modelKey = "daisy.whisperModelID"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModelID
        // Migration: strip old wrongly-prefixed format AND remap names
        // we used during research that don't exist in Argmax's repo.
        var cleaned = stored
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "openai-whisper-", with: "")
        // "large-v3-turbo" was our guess; the actual Argmax folder is
        // suffixed with the v20240930 turbo release date.
        if cleaned == "large-v3-turbo" || cleaned == "large-v3_turbo" {
            cleaned = "large-v3-v20240930"
        }
        let valid = Self.availableModels.map(\.id)
        if !valid.contains(cleaned) {
            cleaned = Self.defaultModelID
        }
        self.modelID = cleaned
        if cleaned != stored {
            UserDefaults.standard.set(cleaned, forKey: Self.modelKey)
        }
    }

    // MARK: - Lifecycle

    func ensureLoaded() async {
        if case .ready = state, kitBox != nil { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func reload() async {
        kitBox = nil
        state = .notLoaded
        downloadProgress = 0
        await ensureLoaded()
    }

    var isReady: Bool {
        if case .ready = state { return kitBox != nil }
        return false
    }

    /// Two-phase load: first explicit download (with progress) then
    /// CoreML init. Splitting lets the UI show a real progress bar
    /// during the 70 MB – 1.5 GB download.
    private func performLoad() async {
        let variant = modelID
        let repo = "argmaxinc/whisperkit-coreml"

        // Phase 1 — download
        state = .downloading(progress: 0)
        downloadProgress = 0

        let folder: URL
        do {
            folder = try await Self.download(variant: variant, repo: repo) { fraction in
                Task { @MainActor in
                    self.downloadProgress = fraction
                    self.state = .downloading(progress: fraction)
                }
            }
        } catch {
            log.error("Whisper download failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Download failed: \(error.localizedDescription)")
            return
        }

        // Phase 2 — load CoreML model
        state = .loading(status: "Initializing CoreML model…")
        do {
            let kit = try await Self.loadKit(folder: folder)
            self.kitBox = WhisperKitBox(kit)
            self.state = .ready
            log.info("WhisperKit ready — model \(variant, privacy: .public)")
        } catch {
            log.error("Whisper load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Init failed: \(error.localizedDescription)")
        }
    }

    /// Off-main download — returns the folder containing the unpacked
    /// CoreML files. Progress is reported via the callback on the main
    /// actor (we hop back).
    nonisolated private static func download(
        variant: String,
        repo: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: variant,
            from: repo,
            progressCallback: { p in
                progress(p.fractionCompleted)
            }
        )
    }

    /// Off-main CoreML init — heavy CPU/Neural Engine work. Stays off
    /// MainActor so it doesn't freeze the UI.
    nonisolated private static func loadKit(folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    // MARK: - In-actor semaphore

    private func acquireSlot() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    // MARK: - Transcribe

    /// Run a transcription pass against 16 kHz mono Float samples.
    /// Multiple callers are serialized. `language` is a two-letter ISO
    /// code ("en", "ru") or nil for auto-detect.
    func transcribe(samples: [Float], language: String?) async throws -> [WhisperSegment] {
        await acquireSlot()
        defer { releaseSlot() }

        await ensureLoaded()
        guard let box = kitBox else { throw WhisperEngineError.notReady }

        // Anti-hallucination knobs. Whisper has a well-documented
        // failure mode where silence or non-speech ambient sound
        // (fans, packing tape, HVAC) gets decoded as text from its
        // YouTube training data — "Thanks for watching!", "ご視聴
        // ありがとうございました", "Спасибо за внимание" etc. The
        // defaults in WhisperKit are conservative; we tighten them.
        //
        //   noSpeechThreshold       — segment dropped if Whisper's
        //                             own "is this non-speech?" prob
        //                             exceeds this. Lower = stricter.
        //                             Default 0.6; we use 0.55.
        //   compressionRatioThreshold — high compression = repetitive
        //                             text ("chocolate chocolate
        //                             chocolate"); above threshold,
        //                             segment is discarded. 2.4 is the
        //                             upstream recommendation.
        //   logProbThreshold        — drop low-confidence segments
        //                             (average log-prob below this).
        //                             -1.0 is the upstream recommendation.
        //   temperatureFallbackCount — re-sample with higher temperature
        //                             up to N times when the above
        //                             filters trigger. 3 gives a fair
        //                             chance to recover from a bad
        //                             greedy decode without burning
        //                             too much latency on real silence.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.55,
            chunkingStrategy: .vad
        )

        let results = try await box.kit.transcribe(audioArray: samples, decodeOptions: options)

        // Post-filter: even with the thresholds above, the most
        // common YouTube-training-set artefacts slip through often
        // enough to wreck the live transcript. Drop them by exact
        // match against a curated blocklist, and collapse adjacent
        // identical lines (also a hallucination signature — real
        // speech rarely repeats verbatim back-to-back across
        // multiple VAD-cut segments).
        var previousText: String?
        return results.flatMap { result in
            result.segments.compactMap { seg -> WhisperSegment? in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                if Self.isKnownHallucination(text) { return nil }
                // Adjacent-duplicate collapse: only fire when the
                // text is long enough that a real repeat is implausible
                // (avoids killing legitimate "yes, yes" or "ok ok").
                if text.count >= 6, text == previousText { return nil }
                previousText = text
                return WhisperSegment(
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: text
                )
            }
        }
    }

    /// Exact-match blocklist of frequent Whisper hallucinations seeded
    /// from YouTube subtitles. Covers the three languages we expect
    /// most ("en", "ru", "ja") plus universal music/applause markers.
    /// Curated from upstream issues and from QA observations
    /// (2026-05-18: tape-and-fan noise produced 8 consecutive
    /// "チョコレートを作る" lines on a quiet desk recording).
    nonisolated static func isKnownHallucination(_ text: String) -> Bool {
        return Self.hallucinationBlocklist.contains(text)
    }

    nonisolated static let hallucinationBlocklist: Set<String> = [
        // Japanese — YouTube outro phrases
        "チョコレートを作る",
        "チョコレートを作る。",
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございました。",
        "ご視聴ありがとうございます",
        "ご視聴ありがとうございます。",
        "ありがとうございました",
        "ありがとうございました。",
        "ありがとうございます",
        "ありがとうございます。",
        "バイバイ",
        "バイバイ。",
        "次回もお楽しみに",
        "次回もお楽しみに。",
        "見てくださってありがとうございました",
        "また次の動画でお会いしましょう",
        "フレッシュ",

        // English — channel-outro boilerplate
        "Thanks for watching!",
        "Thanks for watching.",
        "Thanks for watching",
        "Thank you for watching!",
        "Thank you for watching.",
        "Thank you for watching",
        "Please subscribe to my channel.",
        "Please subscribe to my channel",
        "Subscribe to the channel.",
        "Subscribe to the channel",
        "Don't forget to subscribe!",
        "Don't forget to subscribe",
        "Like and subscribe!",
        "Like and subscribe",
        "Bye.",
        "Bye!",
        "Bye-bye.",
        "Bye-bye!",
        "you",
        "You",
        "Thank you.",
        "Thank you!",

        // Russian — known fansub/subtitler artefacts
        "Спасибо за внимание.",
        "Спасибо за внимание!",
        "Спасибо за внимание",
        "Продолжение следует...",
        "Продолжение следует…",
        "Субтитры делал DimaTorzok",
        "Субтитры сделал DimaTorzok",
        "Субтитры создавал DimaTorzok",
        "Корректор субтитров А.Семкин",
        "Редактор субтитров А.Семкин",

        // Universal sound-effect markers
        "[Music]",
        "[music]",
        "[MUSIC]",
        "[Music playing]",
        "[Applause]",
        "[applause]",
        "[Laughter]",
        "[laughter]",
        "[Inaudible]",
        "♪",
        "♪♪",
        "♪♪♪",
        "(music)",
        "(applause)",
    ]
}

/// Sendable wrapper around the non-Sendable WhisperKit class so we can
/// stash it in a property accessed across actor hops.
final class WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

/// One utterance returned by Whisper, with times in seconds relative to
/// the start of the buffer it was transcribed from.
struct WhisperSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

nonisolated enum WhisperEngineError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return "Whisper model isn't loaded yet. Open Settings → Transcription."
        }
    }
}
