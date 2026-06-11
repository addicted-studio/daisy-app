//
//  DaisyTests.swift
//  DaisyTests
//
//  Pure-function smoke suite. Locks in the highest-bug-yield logic
//  surfaces the pre-1.0.3 audit recommended. No async, no UI, no
//  network — each test is a few-millisecond pure unit assertion.
//

import Testing
import Foundation
import AVFoundation
@testable import Daisy

@Suite("Smoke suite (pure-function regression locks)")
struct DaisyTests {

    // MARK: - resolveSummaryLocaleHint precedence
    //
    // 1.0.3 flipped precedence: explicit picker wins over content
    // detection. This test pins that contract so a future refactor
    // doesn't silently restore detection-first behaviour and
    // recreate the "I picked Polish, why is it Russian?" UX bug.

    @Test("Explicit picker beats content detection")
    func summaryLocaleHint_explicitPickerWins() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "Спасибо за встречу. Передам команде вашу позицию по бюджету и срокам. Завтра пришлю комментарии.",
            transcriptLocale: "ru-RU",
            summaryLanguageOverride: "pl"
        )
        #expect(hint == "pl")
    }

    @Test("Auto + content detection returns detected language")
    func summaryLocaleHint_autoUsesDetector() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "Спасибо за встречу. Передам команде вашу позицию по бюджету и срокам. Завтра пришлю комментарии.",
            transcriptLocale: "auto",
            summaryLanguageOverride: SummaryLanguage.auto.id
        )
        #expect(hint == "ru")
    }

    @Test("Empty transcript with explicit picker still returns picker")
    func summaryLocaleHint_emptyTranscriptStillRespectsPicker() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "",
            transcriptLocale: "auto",
            summaryLanguageOverride: "de"
        )
        #expect(hint == "de")
    }

    // MARK: - CloudSummaryDTO decode tolerance
    //
    // Pre-1.0.3 the decoder threw keyNotFound the moment Sonnet
    // emitted {"lede": "...", "sections": [...]}. 1.0.3 added
    // alias remapping + balanced-brace JSON extraction. These tests
    // pin that tolerance.

    @Test("Decodes the canonical schema cleanly")
    func cloudDTO_decodeCanonical() throws {
        let json = """
        {
          "summary": "Sales call with Altabel.",
          "sections": [
            {
              "title": "Pricing",
              "bullets": [
                { "text": "Monthly subscription with included credits", "children": [] }
              ]
            }
          ],
          "actionItems": ["Maria: send the contract by Thursday"],
          "clientFollowUp": "Thanks for the call..."
        }
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        let summary = dto.toMeetingSummary()
        #expect(summary.summary == "Sales call with Altabel.")
        #expect(summary.sections.count == 1)
        #expect(summary.sections.first?.title == "Pricing")
        #expect(summary.actionItems.count == 1)
        #expect(summary.actionItems.first?.hasPrefix("Maria") == true)
    }

    @Test("Decodes 'lede' alias as summary")
    func cloudDTO_aliasLedeBecomesSummary() throws {
        let json = """
        {
          "lede": "Pricing call recap.",
          "outline": [],
          "action_items": [],
          "follow_up": ""
        }
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        let summary = dto.toMeetingSummary()
        #expect(summary.summary == "Pricing call recap.")
    }

    @Test("Strips Markdown fences and trailing prose")
    func cloudDTO_stripFencesAndTrailingProse() throws {
        let json = """
        Here is the meeting summary:

        ```json
        {
          "summary": "Test.",
          "sections": [],
          "actionItems": [],
          "clientFollowUp": ""
        }
        ```

        Hope that helps!
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        #expect(dto.toMeetingSummary().summary == "Test.")
    }

    // MARK: - RecordingSession.folderAllowed
    //
    // Auto-send folder allow-list. Empty set means "any folder";
    // non-empty restricts. Used by both Notion and MCP auto-send
    // paths. If this regresses, sessions silently route to the
    // wrong destination or get blocked.

    @Test("Empty allow-list permits every folder")
    func folderAllowed_emptyAllowsAll() {
        #expect(RecordingSession.folderAllowed("work", allowed: []) == true)
        #expect(RecordingSession.folderAllowed("personal", allowed: []) == true)
        #expect(RecordingSession.folderAllowed("notes", allowed: []) == true)
    }

    @Test("Non-empty allow-list restricts to listed slugs")
    func folderAllowed_restrictsToListed() {
        let allowed: Set<String> = ["work", "client-x"]
        #expect(RecordingSession.folderAllowed("work", allowed: allowed) == true)
        #expect(RecordingSession.folderAllowed("client-x", allowed: allowed) == true)
        #expect(RecordingSession.folderAllowed("personal", allowed: allowed) == false)
        #expect(RecordingSession.folderAllowed("notes", allowed: allowed) == false)
    }

    // MARK: - LanguageDetector confidence + scope gating
    //
    // Pinned because hallucinated language detection on short or
    // mixed text is what triggers the "summary came back in
    // Japanese" class of bugs. The detector intentionally returns
    // nil below threshold so the fallback path runs.

    @Test("Sub-16-char input returns nil")
    func languageDetector_tooShortReturnsNil() {
        #expect(LanguageDetector.detect("hi") == nil)
        #expect(LanguageDetector.detect("привет!") == nil)
    }

    @Test("Confident Russian detection")
    func languageDetector_clearRussianReturnsRu() {
        let detected = LanguageDetector.detect(
            "Спасибо за встречу. Передам команде вашу позицию по бюджету. Завтра пришлю комментарии."
        )
        #expect(detected == "ru")
    }

    @Test("Confident English detection")
    func languageDetector_clearEnglishReturnsEn() {
        let detected = LanguageDetector.detect(
            "Thanks for jumping on the call. I'll send the budget breakdown by Thursday morning."
        )
        #expect(detected == "en")
    }

    // MARK: - SummaryLabels localisation
    //
    // The UI structural headers (Meeting / Next actions / Follow-up
    // for client / partner) follow the summary language. 1.0.2
    // shipped this for 11 languages — pin so a future refactor
    // doesn't silently revert one of the translations.

    @Test("Russian labels match expected Cyrillic")
    func summaryLabels_russianMatch() {
        let labels = SummaryLabels.for(language: "ru")
        #expect(labels.meeting == "Встреча")
        #expect(labels.nextActions == "Следующие шаги")
        #expect(labels.followUp == "Ответ клиенту / партнёру")
    }

    @Test("Unknown / nil language falls through to English")
    func summaryLabels_unknownReturnsEnglish() {
        let labels1 = SummaryLabels.for(language: nil)
        let labels2 = SummaryLabels.for(language: "xx-XX")
        let labels3 = SummaryLabels.for(language: "auto")
        for labels in [labels1, labels2, labels3] {
            #expect(labels.meeting == "Meeting")
            #expect(labels.nextActions == "Next actions")
            #expect(labels.followUp == "Follow-up for client / partner")
        }
    }
}

// MARK: - Shared audio test helpers
//
// Deterministic synthetic signals only — no microphone, no models,
// no network. AVFoundation's converter/file APIs are pure DSP + file
// IO and run fine on CI without audio hardware.

/// Mono/stereo Float32 PCM buffer filled with a phase-continuous sine
/// on every channel. Returns nil only on allocation failure.
private func makeSineBuffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    frequency: Double,
    amplitude: Float
) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    guard let channels = buffer.floatChannelData else { return nil }
    let increment = 2.0 * Double.pi * frequency / format.sampleRate
    for ch in 0..<Int(format.channelCount) {
        var phase = 0.0
        for i in 0..<Int(frames) {
            channels[ch][i] = amplitude * Float(sin(phase))
            phase += increment
        }
    }
    return buffer
}

/// Raw Float sine samples with an explicit start phase, so chunked
/// callers can keep the waveform continuous across slices.
private func sineSamples(
    count: Int,
    frequency: Double,
    sampleRate: Double,
    amplitude: Float,
    startPhase: Double = 0
) -> (samples: [Float], endPhase: Double) {
    var phase = startPhase
    let increment = 2.0 * Double.pi * frequency / sampleRate
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
        out[i] = amplitude * Float(sin(phase))
        phase += increment
    }
    return (out, phase)
}

/// Write a mono Float32 sine `.caf` to `url`. The AVAudioFile writer is
/// scoped so it deallocates (finalizing the header) before the caller
/// reads the file back.
private func writeSineCAF(
    to url: URL,
    sampleRate: Double,
    frames: AVAudioFrameCount
) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(makeSineBuffer(
        format: format, frames: frames, frequency: 440, amplitude: 0.5
    ))
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}

// MARK: - Audio format conversion (route-change regression locks)
//
// The most expensive historical bug class: a wired-headset/route
// change mid-recording flips the hardware between 44.1 kHz and
// 48 kHz. The fix pins one AVAudioConverter per format and rolls the
// archive into `microphone.partN.caf` parts, each converted
// independently (1.0.7.11 + the full-transcript archive final pass in
// 1.0.7.17). These tests lock the conversion invariants that fix
// relies on: any input rate yields the same 16 kHz duration, and a
// mixed-rate multi-part archive decodes end-to-end.

@Suite("Audio format conversion (route-change regression locks)")
@MainActor
struct AudioFormatConversionTests {

    @Test("44.1 kHz mono input converts to ~1 s of 16 kHz mono output")
    func converter_441kMonoToWhisperFormat() throws {
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let converter = try #require(AudioConverter(inputFormat: input))
        #expect(converter.outputFormat.sampleRate == 16_000)
        #expect(converter.outputFormat.channelCount == 1)

        let buffer = try #require(makeSineBuffer(
            format: input, frames: 44_100, frequency: 440, amplitude: 0.5))
        let samples = try #require(converter.convert(buffer))
        // 1 s of input must come out as ~1 s at 16 kHz (resampler
        // priming may withhold a small head; capacity caps the tail).
        #expect(samples.count > 15_000)
        #expect(samples.count <= 16_100)
        // Amplitude survives resampling (440 Hz is far below Nyquist).
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs > 0.25)
        #expect(maxAbs < 0.75)
    }

    @Test("48 kHz stereo input downmixes + resamples to ~1 s of 16 kHz mono")
    func converter_48kStereoToWhisperFormat() throws {
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let converter = try #require(AudioConverter(inputFormat: input))

        let buffer = try #require(makeSineBuffer(
            format: input, frames: 48_000, frequency: 440, amplitude: 0.5))
        let samples = try #require(converter.convert(buffer))
        #expect(samples.count > 15_000)
        #expect(samples.count <= 16_100)
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs > 0.25)
        #expect(maxAbs < 0.75)
    }

    @Test("Same wall-clock duration converts to the same 16 kHz length for 44.1k and 48k inputs")
    func converter_durationInvariantAcrossRates() throws {
        let f441 = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let f480 = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let c441 = try #require(AudioConverter(inputFormat: f441))
        let c480 = try #require(AudioConverter(inputFormat: f480))

        let b441 = try #require(makeSineBuffer(
            format: f441, frames: 44_100, frequency: 440, amplitude: 0.5))
        let b480 = try #require(makeSineBuffer(
            format: f480, frames: 48_000, frequency: 440, amplitude: 0.5))
        let out441 = try #require(c441.convert(b441))
        let out480 = try #require(c480.convert(b480))
        // The route-change fix depends on this: one second of audio is
        // one second of 16 kHz samples no matter what the hardware
        // rate was when the buffer arrived.
        #expect(abs(out441.count - out480.count) < 800)
    }

    @Test("Mixed-rate multi-part .caf archive decodes to the full duration")
    func archiveDecoder_mixedRatePartsDecodeFully() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulates a mid-session route change: part 1 recorded at
        // 44.1 kHz, part 2 at 48 kHz — 0.5 s each.
        let part1 = dir.appendingPathComponent("microphone.caf")
        let part2 = dir.appendingPathComponent("microphone.part2.caf")
        try writeSineCAF(to: part1, sampleRate: 44_100, frames: 22_050)
        try writeSineCAF(to: part2, sampleRate: 48_000, frames: 24_000)

        let samples = try #require(AudioArchiveDecoder.decodeToMono16k(urls: [part1, part2]))
        // ~1 s total at 16 kHz, allowing per-part resampler priming.
        #expect(samples.count > 14_500)
        #expect(samples.count < 16_500)
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs > 0.25)
    }

    @Test("Decoder returns nil for empty input and missing files")
    func archiveDecoder_nilWhenNothingDecodes() {
        #expect(AudioArchiveDecoder.decodeToMono16k(urls: []) == nil)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-missing-\(UUID().uuidString).caf")
        #expect(AudioArchiveDecoder.decodeToMono16k(urls: [missing]) == nil)
    }

    @Test("Header-only zero-frame part is skipped, not crashed on")
    func archiveDecoder_zeroFramePartSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let huskURL = dir.appendingPathComponent("microphone.caf")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        do {
            // Open + close a writer without writing any frames —
            // exactly the husk a crash-during-start leaves behind.
            _ = try AVAudioFile(
                forWriting: huskURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
        // Nothing decodable → nil (caller falls back to the in-memory
        // buffer), and no crash on the zero-frame file.
        #expect(AudioArchiveDecoder.decodeToMono16k(urls: [huskURL]) == nil)
    }
}

// MARK: - SpectrumAnalyzer (frozen-petals regression locks)
//
// Root cause of the "frozen petals" bug (fixed b7dd919): CoreAudio
// hands ~256–512-frame IO slices, and zero-padding a lone slice into
// the 2048-pt Hann window left it under the near-zero rising edge →
// every band read 0 → the noise gate never opened → petals froze at
// baseline. The fix is a rolling sample window. These tests pin that
// behaviour with synthetic sines — no audio hardware involved.

@Suite("SpectrumAnalyzer (frozen-petals regression locks)")
@MainActor
struct SpectrumAnalyzerTests {

    private let sampleRate: Double = 48_000

    @Test("440 Hz sine lights the 320-640 Hz band hardest")
    func sineLightsCorrectBand() {
        let analyzer = SpectrumAnalyzer()
        let (sine, _) = sineSamples(
            count: 2048, frequency: 440, sampleRate: sampleRate, amplitude: 0.8)
        var bands: [Float] = []
        // Several calls so the asymmetric attack smoothing converges.
        for _ in 0..<10 {
            bands = sine.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        #expect(bands.count == SpectrumAnalyzer.bandCount)
        // Band 2 spans 320-640 Hz — where 440 Hz lives.
        #expect(bands[2] > 0.5)
        for (i, value) in bands.enumerated() {
            #expect(value >= 0)
            #expect(value <= 1)
            if i != 2 {
                #expect(value <= bands[2])
            }
        }
    }

    @Test("Silence after speech decays every band back to rest")
    func silenceDecaysToZero() {
        let analyzer = SpectrumAnalyzer()
        let (sine, _) = sineSamples(
            count: 2048, frequency: 440, sampleRate: sampleRate, amplitude: 0.8)
        var bands: [Float] = []
        for _ in 0..<5 {
            bands = sine.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        // Sanity: the excitation actually registered before we test decay.
        #expect(bands[2] > 0.5)

        let zeros = [Float](repeating: 0, count: 2048)
        for _ in 0..<40 {
            bands = zeros.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        for value in bands {
            #expect(value < 0.01)
        }
    }

    @Test("Empty buffer neither crashes nor disturbs state")
    func emptyBufferIsSafe() {
        let analyzer = SpectrumAnalyzer()
        let empty: [Float] = []
        let bands = empty.withUnsafeBufferPointer {
            analyzer.bands(from: $0, sampleRate: sampleRate)
        }
        #expect(bands.count == SpectrumAnalyzer.bandCount)
        for value in bands {
            #expect(value >= 0)
            #expect(value <= 1)
        }
    }

    @Test("256-sample CoreAudio-style slices accumulate via the rolling window")
    func smallSlicesAccumulateSpectrum() {
        // THE frozen-petals scenario: tiny IO slices. With the old
        // zero-padded single-buffer FFT these stayed under the Hann
        // rising edge and every band read 0 forever. The rolling
        // window must build a full spectrum out of them.
        let analyzer = SpectrumAnalyzer()
        var phase = 0.0
        var bands: [Float] = []
        for _ in 0..<40 {
            let (chunk, endPhase) = sineSamples(
                count: 256, frequency: 440, sampleRate: sampleRate,
                amplitude: 0.8, startPhase: phase)
            phase = endPhase
            bands = chunk.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        #expect(bands[2] > 0.3)
        #expect((bands.max() ?? 0) > 0.3)
    }

    @Test("reset() clears the rolling window, not just the smoothing")
    func resetClearsRollingWindow() {
        let analyzer = SpectrumAnalyzer()
        let (sine, _) = sineSamples(
            count: 2048, frequency: 440, sampleRate: sampleRate, amplitude: 0.8)
        for _ in 0..<5 {
            _ = sine.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        analyzer.reset()
        // An empty call FFTs whatever is left in the window. If reset
        // didn't clear history, the previous recording's tail would
        // re-light the bands here.
        let empty: [Float] = []
        let bands = empty.withUnsafeBufferPointer {
            analyzer.bands(from: $0, sampleRate: sampleRate)
        }
        for value in bands {
            #expect(value < 0.01)
        }
    }
}

// MARK: - Level meters (-160 dB sentinel locks)
//
// The Bluetooth capture watchdog keys off the -160 dB sentinel
// (BT-output drags the mic to silence → -160 → pause/warning). If
// these helpers ever return NaN/-inf instead, the watchdog and the
// red-widget warning both misbehave.

@Suite("Level meters (-160 dB sentinel locks)")
@MainActor
struct AudioLevelMeterTests {

    @Test("Silent buffer reads exactly the -160 sentinel")
    func silenceReadsSentinel() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(makeSineBuffer(
            format: format, frames: 1024, frequency: 440, amplitude: 0))  // amplitude 0 == explicit silence
        #expect(CoreAudioMicRecorder.peakLevelDB(of: buffer) == -160)
        #expect(CoreAudioMicRecorder.rmsLevelDB(of: buffer) == -160)
    }

    @Test("Zero-length buffer reads -160, never NaN or -inf")
    func zeroFramesReadSentinel() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 0
        #expect(CoreAudioMicRecorder.peakLevelDB(of: buffer) == -160)
        #expect(CoreAudioMicRecorder.rmsLevelDB(of: buffer) == -160)
    }

    @Test("Full-scale sine: peak ~0 dBFS, RMS ~-3 dB")
    func fullScaleSineLevels() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        // 4800 frames at 440 Hz / 48 kHz = exactly 44 periods, so the
        // RMS is exactly 1/sqrt(2) up to sampling granularity.
        let buffer = try #require(makeSineBuffer(
            format: format, frames: 4800, frequency: 440, amplitude: 1.0))
        let peak = CoreAudioMicRecorder.peakLevelDB(of: buffer)
        #expect(peak > -0.2)
        #expect(peak <= 0.01)
        let rms = CoreAudioMicRecorder.rmsLevelDB(of: buffer)
        #expect(abs(rms - (-3.01)) < 0.2)
    }
}

// MARK: - Search tokenizer (inverted-index prefilter locks)
//
// `SessionStore.sessionsMatching` prefilters with an inverted token
// index whose correctness contract is: tokenization must split and
// lowercase EXACTLY like `StoredSession.matches` lowercases, or the
// index drops true matches (silent search misses — the worst kind).

@Suite("Search tokenizer (inverted-index prefilter locks)")
@MainActor
struct SearchTokenizerTests {

    @Test("Cyrillic, Latin, and digits tokenize lowercased")
    func mixedAlphabetsTokenize() {
        #expect(SessionStore.searchTokens(in: "Встреча с MediaCube — бюджет 2026!")
            == ["встреча", "с", "mediacube", "бюджет", "2026"])
        #expect(SessionStore.searchTokens(in: "v2.0-beta") == ["v2", "0", "beta"])
        #expect(SessionStore.searchTokens(in: "ПРИВЕТ-Отчёт") == ["привет", "отчёт"])
    }

    @Test("Punctuation-only and empty input yield no tokens")
    func punctuationYieldsNothing() {
        #expect(SessionStore.searchTokens(in: "") == [])
        #expect(SessionStore.searchTokens(in: "?!… — ,,, ///") == [])
        #expect(SessionStore.searchTokens(in: "   \n\t  ") == [])
    }

    @Test("Order is preserved and duplicates are kept")
    func orderAndDuplicatesPreserved() {
        // sessionsMatching's multi-token candidate logic (suffix /
        // exact / prefix positions) depends on token ORDER, so the
        // tokenizer must not Set-ify.
        #expect(SessionStore.searchTokens(in: "так и так") == ["так", "и", "так"])
        #expect(SessionStore.searchTokens(in: "hello world hello") == ["hello", "world", "hello"])
    }
}

// MARK: - WhisperEngine.DecodeProfile knob locks
//
// Cheap lock so a refactor can't silently swap the live-pass `.lite`
// knobs onto the quality path (or vice versa). `.dictationFinal`'s
// single retry exists because its output is pasted verbatim — see the
// DecodeProfile doc comment.

@Suite("WhisperEngine.DecodeProfile knob locks")
@MainActor
struct DecodeProfileTests {

    @Test(".full keeps the historical quality knobs: 3 retries, topK 5, 16 workers")
    func fullProfileKnobs() {
        let p = WhisperEngine.DecodeProfile.full
        #expect(p.temperatureFallbackCount == 3)
        #expect(p.topK == 5)
        #expect(p.concurrentWorkerCount == 16)
    }

    @Test(".lite is greedy and retry-free: 0 retries, topK 1, 4 workers")
    func liteProfileKnobs() {
        let p = WhisperEngine.DecodeProfile.lite
        #expect(p.temperatureFallbackCount == 0)
        #expect(p.topK == 1)
        #expect(p.concurrentWorkerCount == 4)
    }

    @Test(".dictationFinal sits between: 1 retry, topK 1, 4 workers")
    func dictationFinalProfileKnobs() {
        let p = WhisperEngine.DecodeProfile.dictationFinal
        #expect(p.temperatureFallbackCount == 1)
        #expect(p.topK == 1)
        #expect(p.concurrentWorkerCount == 4)
    }
}
