//
//  RecordingSession+Dictation.swift
//  Daisy
//
//  Post-Stop handling for DICTATION mode, lifted out of the giant `stop()`
//  in RecordingSession.swift (architecture cleanup — behaviour unchanged).
//  Dictation is fully ephemeral: transcribe the held mic buffer (fast
//  engine → Whisper fallback), optionally rewrite it in the user's voice,
//  record usage, paste, and tear the session down. Nothing is saved to
//  Library.
//

import Foundation
import os

extension RecordingSession {
    /// Finalize a `.dictation` session and paste the result. `durSec` is
    /// the recorded length (passed from `stop()`, which already computed
    /// it). Runs INLINE on Stop — the paste waits on it — so every step is
    /// latency-conscious (lite decode, an 8 s polish deadline).
    func finishDictation(durSec: Int) async {
        let signposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "Dictation")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        var transcriptText: String
        let samples = micTranscriber.capturedSamples

        // Fast-engine attempt (Parakeet or Apple SpeechAnalyzer) — both
        // transcribe the captured mic buffer directly, skipping the Whisper
        // final pass. Any miss (off, error, empty, or — for Apple — pre-26 /
        // "auto" locale / model not yet installed) drops through to Whisper.
        var fastText: String? = nil
        switch settings.dictationEngine {
        case .whisper:
            break
        case .parakeet:
            fastText = try? await ParakeetEngine.shared.transcribe(samples: samples)
        case .appleSpeech:
            // SpeechTranscriber needs a concrete language and macOS 26.
            let localeID = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
            if #available(macOS 26, *), localeID != "auto", !localeID.isEmpty {
                let locale = Locale(identifier: localeID)
                if await AppleSpeechEngine.isUsable(locale: locale),
                   await AppleSpeechEngine.ensureModelReady(locale: locale) {
                    fastText = try? await AppleSpeechEngine.shared.transcribe(samples: samples, locale: locale)
                }
            }
        }

        if let fastText, !fastText.isEmpty {
            transcriptText = fastText
        } else {
            // Whisper path — default, and the automatic fallback when the
            // fast engine is off, errored, or produced nothing (e.g. a
            // sub-0.3 s clip, or Apple's model still downloading).
            //
            // `.dictationFinal` (lite search width + one temperature-
            // fallback retry) instead of `.full`: this decode blocks the
            // paste, and full-width search on a few seconds of speech is
            // latency without measurable quality gain.
            let dictFinalState = signposter.beginInterval("dictation_final_pass", id: signposter.makeSignpostID())
            let t_dictFinal = Date()
            await micTranscriber.runFinalPass(profile: .dictationFinal, biasTerms: DictationDictionary.shared.biasTerms())
            signposter.endInterval("dictation_final_pass", dictFinalState)
            log.info("post-stop dictation_final_pass: \(ms(t_dictFinal), privacy: .public)ms")
            transcriptText = fullTranscriptText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Optional: rewrite in the user's voice via the local profile
        // before pasting. Opt-in (adds one LLM pass); no-op without a
        // generated profile. Failure / timeout → keep the un-polished text.
        if settings.polishDictationInMyVoice,
           let instruction = VoiceProfileStore.shared.profile?.styleInstruction,
           !instruction.isEmpty, !transcriptText.isEmpty {
            let polishState = signposter.beginInterval("dictation_polish", id: signposter.makeSignpostID())
            let t_polish = Date()
            if let polished = await Self.polishWithDeadline(
                text: transcriptText, instruction: instruction, seconds: 8
            ), !polished.isEmpty {
                // Count words the rewrite changed (insertions in a word-level
                // diff) for the "fixes made by Daisy" widget.
                let before = transcriptText.split(whereSeparator: { $0.isWhitespace })
                let after = polished.split(whereSeparator: { $0.isWhitespace })
                let changed = after.difference(from: before).insertions.count
                UsageStats.shared.recordFixes(polished: changed)
                transcriptText = polished
            }
            signposter.endInterval("dictation_polish", polishState)
            log.info("post-stop dictation_polish: \(ms(t_polish), privacy: .public)ms")
        }

        // Local usage stats (powers the Home words/min · total words ·
        // activity widgets). Dictation is otherwise ephemeral, so this is
        // the only record of it — count words + the held duration.
        UsageStats.shared.record(
            words: UsageStats.wordCount(transcriptText),
            seconds: Double(max(0, durSec)),
            kind: .dictation
        )
        DictationPaste.shared.handle(transcript: transcriptText)
        if let dir = sessionDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        releaseSessionsFolderTicket()
        reset()
    }
}
