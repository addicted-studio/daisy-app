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

    /// The user's own MEETING speech, kept in its OWN store rather than
    /// merged into `corpus`.
    ///
    /// Separate on purpose: the toggle that feeds it
    /// (`includesMeetings`) has to be reversible,
    /// and a single blended blob has no provenance — once merged there is
    /// no way to un-merge, so turning the toggle back off could only be
    /// honest by wiping dictations too. With two stores, off simply stops
    /// counting this one, and on again costs nothing to restore.
    private static let meetingCorpusKey = "daisy.voiceCorpus.meetings"

    private(set) var meetingCorpus: String
    private(set) var meetingCorpusWords: Int

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
        let storedMeetings = UserDefaults.standard.string(forKey: Self.meetingCorpusKey) ?? ""
        meetingCorpus = storedMeetings
        meetingCorpusWords = UsageStats.wordCount(storedMeetings)
        // Absent key → false. Opt-in by design.
        includesMeetings = UserDefaults.standard.bool(forKey: Self.includeMeetingsKey)
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

    /// Whether meeting speech is currently counted, and the single source
    /// of truth for it.
    ///
    /// Owned here rather than in AppSettings so it sits INSIDE this
    /// store's `@Observable` graph: `effectiveWords`, `unlockProgress`
    /// and `isUnlocked` all depend on it, and had the flag lived
    /// elsewhere those would only refresh by luck — whenever some view
    /// happened to also read the settings object in the same body.
    /// Persisted by this store, like the corpus and the profile.
    private(set) var includesMeetings: Bool

    private static let includeMeetingsKey = "daisy.voiceProfileIncludeMeetings"

    /// Words the profile would actually be built from right now —
    /// dictations always, plus meetings while the toggle is on.
    var effectiveWords: Int {
        corpusWords + (includesMeetings ? meetingCorpusWords : 0)
    }

    /// True once enough of the user's own words have accumulated.
    var isUnlocked: Bool { hasProfile || effectiveWords >= Self.unlockWords }

    /// 0…1 progress toward the unlock (for the "learning your voice" bar).
    var unlockProgress: Double {
        min(1, Double(effectiveWords) / Double(Self.unlockWords))
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

    /// Flip the meetings switch. Persisted immediately; the caller is
    /// responsible for seeding from the existing library when turning it
    /// on (`VoiceView.seedFromLibrary`).
    func setIncludesMeetings(_ on: Bool) {
        guard includesMeetings != on else { return }
        includesMeetings = on
        UserDefaults.standard.set(on, forKey: Self.includeMeetingsKey)
    }

    /// Feed the user's own MEETING speech into the meeting corpus.
    ///
    /// Callers MUST pass microphone-stream text only. Two of them exist:
    /// the post-stop hook in `RecordingSession.finalize`, which filters
    /// `segments` by `source == .microphone`, and
    /// `ownSpeech(inTranscript:displayName:)` for transcripts already on
    /// disk. Nothing here re-checks — the filtering is the caller's job.
    func appendMeetingSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = meetingCorpus.isEmpty ? trimmed : meetingCorpus + "\n\n" + trimmed
        if updated.count > Self.maxCorpusStoredChars {
            updated = String(updated.suffix(Self.maxCorpusStoredChars))
        }
        meetingCorpus = updated
        meetingCorpusWords = UsageStats.wordCount(updated)
        UserDefaults.standard.set(updated, forKey: Self.meetingCorpusKey)
    }

    /// The text a profile is actually built from.
    ///
    /// Each source gets its own half of the budget instead of being
    /// concatenated and tail-trimmed as one blob. Concatenating looks
    /// fine and silently isn't: the dictation corpus alone can reach
    /// 16k characters, so an 8k tail would be 100% dictation and the
    /// meeting text would be counted in the progress bar while never
    /// reaching the model. Halves also keep the ratio honest — the
    /// profile reflects both sources rather than whichever happened to
    /// be longer. Each half keeps its most RECENT text.
    private var corpusForGeneration: String {
        guard includesMeetings, !meetingCorpus.isEmpty else {
            return String(corpus.suffix(Self.maxCorpusChars))
        }
        guard !corpus.isEmpty else {
            return String(meetingCorpus.suffix(Self.maxCorpusChars))
        }
        let half = Self.maxCorpusChars / 2
        return String(meetingCorpus.suffix(half)) + "\n\n" + String(corpus.suffix(half))
    }

    /// Build (or rebuild) the profile from the user's recent dictations.
    /// Hard cap on what's SENT to the provider — bounds token cost and
    /// what leaves the Mac on a cloud provider. Keeps the most RECENT text
    /// (the stored corpus may be up to 16k chars).
    private static let maxCorpusChars = 8_000

    func generate() async {
        // Already budgeted per source — no second trim here, or it would
        // shave the front off the meeting half.
        let sample = corpusForGeneration.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Meetings already in the Library

    /// One-time fill of the meeting corpus from transcripts already on
    /// disk, run when the toggle is switched on. Without it the setting
    /// would do nothing until the NEXT meeting — useless to the person who
    /// turns it on precisely because they already have dozens recorded
    /// (the 2026-07-27 report: 76 meetings, profile stuck at 0 of 300).
    ///
    /// Newest first, stopping at the stored cap, so a long library
    /// contributes its most recent speech rather than its oldest.
    /// No-op once the meeting corpus holds anything, so flipping the
    /// toggle off and on doesn't re-scan.
    @discardableResult
    func backfillFromMeetings(sessions: [StoredSession], displayName: String) -> Int {
        guard meetingCorpus.isEmpty else { return 0 }
        let before = meetingCorpusWords
        var collected: [String] = []
        var chars = 0
        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            // Meetings only — `.note` is a voice note. The switch says
            // "meetings", and the post-stop hook is gated the same way,
            // so a voice note is treated identically whether it was
            // recorded before or after the switch was flipped.
            guard session.kind == .recording else { continue }
            let own = Self.ownSpeech(inTranscript: session.transcriptText, displayName: displayName)
            guard !own.isEmpty else { continue }
            collected.append(own)
            chars += own.count
            if chars >= Self.maxCorpusStoredChars { break }
        }
        guard !collected.isEmpty else { return 0 }
        // Reverse so the text reads oldest → newest, matching how the
        // dictation corpus grows; the tail-trim then keeps recent speech.
        appendMeetingSpeech(collected.reversed().joined(separator: "\n\n"))
        let added = max(0, meetingCorpusWords - before)
        log.info("Voice corpus: seeded \(added, privacy: .public) words of own meeting speech")
        return added
    }

    /// Pull ONLY the user's own lines out of an exported transcript.
    ///
    /// MarkdownExporter writes every line as `**[mm:ss · Label]** text`,
    /// and the label tells us the stream: the microphone side is the
    /// user's display name, `Me`, or `Speaker <id>` (mic-side diarization
    /// with no name set), while the remote side is always `Remote…`
    /// (`TranscriptSegment.speakerLabel`).
    ///
    /// This matches the mic labels by ALLOW-LIST rather than excluding
    /// `Remote…`, and that asymmetry is deliberate: a remote speaker
    /// renamed through the speaker map would slip past an exclusion rule
    /// and quietly train the profile on someone else's voice. Missing some
    /// of the user's own older lines — e.g. recorded under a display name
    /// they've since changed — is the cheaper error by far.
    nonisolated static func ownSpeech(inTranscript transcript: String, displayName: String) -> String {
        let myName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [String] = []
        for rawLine in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.hasPrefix("**["), let close = line.range(of: "]**") else { continue }
            let inside = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            // `[mm:ss · Label]` — the label is everything after the
            // separator. No separator means an unexpected shape; skip it
            // rather than guess.
            guard let sep = inside.range(of: " · ") else { continue }
            let label = inside[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            let lower = label.lowercased()
            let isMine = lower == "me"
                || (!myName.isEmpty && lower == myName)
                || label.hasPrefix("Speaker ")
            guard isMine else { continue }
            let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
        }
        return out.joined(separator: " ")
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
