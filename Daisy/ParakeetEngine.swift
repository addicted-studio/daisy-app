//
//  ParakeetEngine.swift
//  Daisy
//
//  On-device Parakeet TDT v3 ASR (FluidAudio / CoreML / Apple Neural
//  Engine) — an EXPERIMENTAL alternative to WhisperEngine for the
//  dictation path only. FluidAudio is already a Daisy dependency
//  (diarization + Silero VAD), so this adds the ASR engine without a new
//  package: the library is linked, only the ~600 MB v3 model downloads on
//  first use. Parakeet is a streaming transducer (much lower decode
//  latency than Whisper's 30 s-window batch model) and covers 25 European
//  languages incl. Russian/Ukrainian.
//
//  Gated behind `AppSettings.dictationUseParakeet` (default OFF). Shipped
//  dark so we can A/B latency + RU quality on real dictation before
//  making it the default or adding a UI toggle. See the research note
//  2026-06-04-dictation-latency-optimization.
//
//  API note (FluidAudio @ 9782d877): the convenience `transcribe(_:source:)`
//  shown in FluidAudio's docs is AHEAD of the pinned commit — the actual
//  public method is `transcribe(_ samples:decoderState:language:)`, which
//  we drive with a fresh `TdtDecoderState` per one-shot dictation.
//

import Foundation
import Observation
import os
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
@Observable
final class ParakeetEngine {
    enum LoadState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    static let shared = ParakeetEngine()

    private(set) var state: LoadState = .notLoaded

    #if canImport(FluidAudio)
    @ObservationIgnored
    private var manager: AsrManager?
    #endif
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Parakeet")

    private init() {}

    var isReady: Bool {
        if case .ready = state {
            #if canImport(FluidAudio)
            return manager != nil
            #else
            return false
            #endif
        }
        return false
    }

    /// Idempotent load: download (first run only — ~600 MB for v3 int8) and
    /// initialize the `AsrManager`. Concurrent callers await the same
    /// in-flight load. Non-throwing — failures land in `state = .failed`
    /// and `transcribe` then throws `notReady`.
    func ensureLoaded() async {
        #if canImport(FluidAudio)
        if case .ready = state, manager != nil { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
        #endif
    }

    #if canImport(FluidAudio)
    private func performLoad() async {
        if case .ready = state, manager != nil { return }
        state = .downloading(progress: 0)
        log.info("Parakeet: downloading/loading v3 (int8)…")
        do {
            // v3 = multilingual (incl. RU/UK). Default encoder precision is
            // int8; models cache on disk after the first download. The
            // progress handler is @Sendable + called off-main, so hop back
            // to MainActor to update observable state (drives the Settings
            // download bar). fractionCompleted spans download→compile 0…1.
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .ready = self.state { return }
                        self.state = .downloading(progress: fraction)
                    }
                }
            )
            state = .loading
            // init(config:models:) wires the models in synchronously — the
            // actor reports `isAvailable == true` immediately after.
            self.manager = AsrManager(config: .default, models: models)
            state = .ready
            log.info("Parakeet ASR ready (v3)")
        } catch {
            self.manager = nil
            state = .failed(error.localizedDescription)
            log.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Transcribe 16 kHz mono Float samples → trimmed text. Throws if the
    /// engine isn't available or the clip is too short (FluidAudio rejects
    /// sub-~0.3 s audio). Uses a fresh decoder state per call (one-shot
    /// batch transcription — no cross-utterance streaming context).
    func transcribe(samples: [Float]) async throws -> String {
        #if canImport(FluidAudio)
        await ensureLoaded()
        guard let manager else { throw ParakeetEngineError.notReady }
        var decoderState = TdtDecoderState.make()   // 2 LSTM layers (v2/v3)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw ParakeetEngineError.notReady
        #endif
    }
}

nonisolated enum ParakeetEngineError: LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return "Parakeet ASR isn’t available yet."
        }
    }
}
