//
//  AppleSpeechLiveEngine.swift
//  Daisy
//
//  Live (streaming) transcription backed by Apple's SpeechAnalyzer /
//  SpeechTranscriber (macOS 26+). Used as the "Lite" live engine:
//   • the recognition model lives in the system asset catalog →
//     ZERO app memory (unlike a second resident WhisperKit instance);
//   • volatile/finalized results map directly onto Transcriber's
//     pending/committed model (`Result.isFinal`);
//   • ~2× faster than Whisper turbo on the same audio.
//
//  ONLY the live preview runs through this. The authoritative pass on
//  Stop is always WhisperKit turbo — it carries diarization + language
//  detection, which SpeechTranscriber does not. On macOS < 26, an
//  unsupported/auto locale, a not-yet-installed model, or any error,
//  `Transcriber` transparently falls back to the Whisper-Lite decode
//  profile (the rolling-window timer path).
//

import Foundation
import AVFoundation
import CoreMedia
import Speech
import os

/// One live result chunk, normalized to the session-relative shape the
/// `Transcriber` consumes. Times are relative to the engine's first fed
/// buffer; `Transcriber` adds its own start offset.
struct AppleLiveResult: Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
    let isFinal: Bool
}

@available(macOS 26, *)
@MainActor
final class AppleSpeechLiveEngine {
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppleSpeechLiveEngine")

    private let locale: Locale
    private let onResult: @MainActor (AppleLiveResult) -> Void

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    init(locale: Locale, onResult: @escaping @MainActor (AppleLiveResult) -> Void) {
        self.locale = locale
        self.onResult = onResult
    }

    /// SpeechTranscriber exists on this machine AND the locale is
    /// supported. Call before constructing/starting an instance.
    static func isUsable(locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    /// Whether the locale's on-device model is installed *right now*. If
    /// it isn't, kicks a best-effort background download (so a later
    /// session can use Apple) and returns false — the caller falls back
    /// to Whisper-Lite for this session rather than blocking on a large
    /// model pull.
    static func ensureModelReady(locale: Locale) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return false
        }
        let target = supported.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) {
            return true
        }
        Task.detached {
            do {
                let probe = SpeechTranscriber(
                    locale: supported,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange]
                )
                try await AssetInventory.reserve(locale: supported)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                // Best-effort; Whisper-Lite covers this session regardless.
            }
        }
        return false
    }

    func start() async throws {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Drain results → normalized callback. Inherits MainActor from
        // the enclosing isolation, so `onResult` is called on the main
        // actor as Transcriber requires.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let normalized = AppleLiveResult(
                        text: String(result.text.characters),
                        startSec: result.range.start.seconds,
                        endSec: result.range.end.seconds,
                        isFinal: result.isFinal
                    )
                    self.onResult(normalized)
                }
            } catch {
                self.log.error("Apple results stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)
    }

    /// Convert a captured buffer to the analyzer's format and feed it.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation, let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        converterInput = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = analyzerFormat else { return buffer }
        if buffer.format == targetFormat { return buffer }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var convError: NSError?
        // The input block runs synchronously inside `convert`, so handing it
        // the (non-Sendable) buffer is safe — opt out of the @Sendable capture
        // check explicitly rather than broadly @preconcurrency-ing AVFAudio.
        nonisolated(unsafe) let input = buffer
        let status = converter.convert(to: out, error: &convError) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return input
        }
        if status == .haveData || status == .inputRanDry {
            return out.frameLength > 0 ? out : nil
        }
        return nil
    }
}
