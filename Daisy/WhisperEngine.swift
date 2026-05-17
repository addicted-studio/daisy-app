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

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )

        let results = try await box.kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { result in
            result.segments.map {
                WhisperSegment(
                    start: Double($0.start),
                    end: Double($0.end),
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }
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
