//
//  VoiceProfile.swift
//  Daisy
//
//  A local "voice profile" — a description of how the user writes/speaks,
//  built by analyzing a corpus of their own recent dictations through the
//  selected summary provider. Two jobs:
//    • display — a readable profile (tone, signature phrases, quirks) in
//      the Voice section, reusing the MeetingSummary outline shape;
//    • function — a compact `styleInstruction` that conditions the
//      optional "polish dictation in my voice" rewrite (AppSettings
//      `polishDictationInMyVoice`).
//
//  100% local when the provider is local. The corpus is the user's own
//  dictation history (never leaves the Mac unless a cloud provider is
//  chosen — same contract as summaries).
//

import Foundation
import Observation
import os

struct VoiceProfile: Codable, Sendable, Equatable {
    let generatedAt: Date
    /// Word count of the corpus it was built from (shown as confidence).
    let sampleWords: Int
    /// Readable profile for the UI (summary + sections). Reuses
    /// MeetingSummary purely as a display container.
    let display: MeetingSummary
    /// Compact directive fed to the polish rewrite. Derived from the
    /// profile's `clientFollowUp`.
    let styleInstruction: String
}

@MainActor
@Observable
final class VoiceProfileStore {
    static let shared = VoiceProfileStore()

    enum State: Equatable {
        case idle
        case generating
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var profile: VoiceProfile?

    /// Rolling corpus of the user's own dictations, accumulated across
    /// sessions (dictations themselves are ephemeral; the 24h history is
    /// too thin to profile from). Newest-suffix capped. Local-only, used
    /// exclusively for the voice profile.
    private(set) var corpus: String
    private(set) var corpusWords: Int

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "VoiceProfile")
    private static let key = "daisy.voiceProfile"
    private static let corpusKey = "daisy.voiceCorpus"
    private static let maxCorpusStoredChars = 16_000

    /// Wispr-style unlock: the profile isn't offered until enough real
    /// dictation has accumulated to say something meaningful.
    static let unlockWords = 300

    private init() {
        // Read into a local first — @Observable rewrites stored properties
        // into accessors, so reading `self.corpus` before every stored
        // property is initialized is a phase-1 init error.
        let storedCorpus = UserDefaults.standard.string(forKey: Self.corpusKey) ?? ""
        corpus = storedCorpus
        corpusWords = UsageStats.wordCount(storedCorpus)
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(VoiceProfile.self, from: data) {
            profile = decoded
            state = .ready
        }
        // Seed from the rolling 24h history once (existing users who
        // dictated before the corpus shipped shouldn't start from zero).
        if corpus.isEmpty {
            let seed = DictationHistory.shared.entries.map(\.text).joined(separator: "\n\n")
            if !seed.isEmpty { appendDictation(seed) }
        }
    }

    var hasProfile: Bool { profile != nil }

    /// True once enough dictation has accumulated to offer generation.
    var isUnlocked: Bool { hasProfile || corpusWords >= Self.unlockWords }

    /// 0…1 progress toward the unlock (for the "learning your voice" bar).
    var unlockProgress: Double {
        min(1, Double(corpusWords) / Double(Self.unlockWords))
    }

    /// Feed a finished dictation into the corpus (called from the paste
    /// path). Keeps the newest `maxCorpusStoredChars` characters.
    func appendDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = corpus.isEmpty ? trimmed : corpus + "\n\n" + trimmed
        if updated.count > Self.maxCorpusStoredChars {
            updated = String(updated.suffix(Self.maxCorpusStoredChars))
        }
        corpus = updated
        corpusWords = UsageStats.wordCount(updated)
        UserDefaults.standard.set(updated, forKey: Self.corpusKey)
    }

    /// Build (or rebuild) the profile from the user's recent dictations.
    /// Hard cap on what's SENT to the provider — bounds token cost and
    /// what leaves the Mac on a cloud provider. Keeps the most RECENT text
    /// (the stored corpus may be up to 16k chars).
    private static let maxCorpusChars = 8_000

    func generate() async {
        var sample = corpus.trimmingCharacters(in: .whitespacesAndNewlines)
        if sample.count > Self.maxCorpusChars {
            sample = String(sample.suffix(Self.maxCorpusChars))
        }
        let words = UsageStats.wordCount(sample)
        guard isUnlocked, words > 0 else {
            state = .failed(String(localized: "Keep dictating — your profile unlocks once Daisy has heard enough of your voice."))
            return
        }

        state = .generating
        do {
            let summary = try await Summarizer.shared.runProbe(
                transcript: sample,
                title: "Voice profile",
                localeHint: nil,
                task: .voiceProfile
            )
            let built = VoiceProfile(
                generatedAt: Date(),
                sampleWords: words,
                display: summary,
                styleInstruction: summary.clientFollowUp
            )
            profile = built
            persist(built)
            state = .ready
            log.info("Voice profile generated from \(words, privacy: .public) words")
        } catch {
            state = .failed(error.localizedDescription)
            log.error("Voice profile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Seeding without waiting for dictation

    /// Import the user's OWN writing (pasted text / .txt / .md — emails,
    /// posts, an export from another dictation app) into the corpus.
    /// Same pipeline as dictated words: fills the unlock bar and may
    /// unlock immediately. Returns the words added.
    @discardableResult
    func importSamples(_ text: String) -> Int {
        let before = corpusWords
        appendDictation(text)
        return max(0, corpusWords - before)
    }

    /// Power-user path: the user already HAS a style instruction (e.g.
    /// carried over from another app). Installs it as the profile
    /// directly — no corpus, no LLM call. The instruction doubles as the
    /// display summary so the Voice card shows what's driving the polish.
    func setCustomInstruction(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let built = VoiceProfile(
            generatedAt: Date(),
            sampleWords: UsageStats.wordCount(trimmed),
            display: MeetingSummary(
                summary: trimmed,
                sections: [],
                actionItems: [],
                clientFollowUp: trimmed
            ),
            styleInstruction: trimmed
        )
        profile = built
        persist(built)
        state = .ready
        log.info("Voice profile set from a custom style instruction")
    }

    func clear() {
        profile = nil
        state = .idle
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func persist(_ profile: VoiceProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
