//
//  AcousticEchoDedup.swift
//  Daisy
//
//  Post-merge text-similarity pass that drops mic-side transcript
//  segments which look like acoustic echoes of nearby system-audio
//  segments. Targets the failure mode where a user plays meeting
//  audio through the laptop speakers (instead of headphones): the
//  microphone re-captures that same audio and Whisper transcribes
//  it on the mic side. Result without this pass: every line in the
//  transcript appears twice — once correctly labeled "Remote", once
//  wrongly labeled with the user's name.
//
//  Algorithm (called from `MarkdownExporter.renderMarkdown` when
//  `AppSettings.suppressAcousticEcho` is on):
//
//    1. Walk `segments` (already sorted by `startedAt`).
//    2. For each MIC-side segment, search ±2 seconds around its
//       start time for any SYSTEM-side segment with matching text,
//       by EITHER:
//         • near-equal length (±20%) + Levenshtein similarity > 0.8, OR
//         • containment — the shorter normalized text (≥12 chars) is a
//           substring of the longer one. Handles the common case where
//           one stream emits a whole sentence as a single segment while
//           the other splits it into 2-3 chunks (the ±20% length gate
//           alone rejected those, so echoes leaked through — observed on
//           the 2026-05-31 Billions-through-speakers test).
//    3. Mark the mic segment as an echo candidate.
//    4. After the full pass: drop runs of ≥3 consecutive echo
//       candidates outright (confirmed echo — extremely unlikely
//       to be the user repeating multiple lines verbatim by
//       coincidence). Isolated single matches are KEPT on the
//       assumption they're legitimate quoting ("ты сказал X").
//
//  Why not Apple-AEC at the audio-graph level: would require
//  rebuilding the AVAudioEngine + ScreenCaptureKit capture chain
//  with `kAudioUnitSubType_VoiceProcessingIO`, which isn't drop-in
//  for ScreenCaptureKit's audio output. Headphones still solve at
//  the source — this is the 90% software mitigation for users who
//  haven't put them on.
//

import Foundation

enum AcousticEchoDedup {

    /// Window around a mic segment's start time within which a
    /// system-audio segment can match as an echo source. Wide enough
    /// to cover speaker→mic latency (50-200ms) plus Whisper segment-
    /// start drift (~1-2s between mic and system streams hearing the
    /// same waveform).
    private static let matchWindowSec: Double = 2.0

    /// Length-ratio bound: |mic_len - sys_len| / max(...) must be
    /// ≤ this fraction for a candidate match. Catches cases where
    /// Whisper segmented the same audio into slightly different
    /// chunks on each stream.
    private static let lengthRatioTolerance: Double = 0.20

    /// Normalized similarity threshold (0..1, where 1 = identical).
    /// 0.8 was chosen on the 2026-05-25 Billions test: SRT lines vs
    /// Daisy mic-echo lines averaged 0.85-0.95 similarity; legitimate
    /// quoting ("ты сказал X") rarely exceeds 0.6 because the user's
    /// surrounding words break the match.
    private static let similarityThreshold: Double = 0.80

    /// Minimum length (normalized chars) of the shorter segment for the
    /// containment path to fire. Below this, short fillers ("да", "нет",
    /// "хорошо") would be a substring of almost any longer line. ~12
    /// chars ≈ 2-3 Russian words. The ≥3-consecutive run rule still
    /// backstops a false single match.
    private static let minContainmentLen: Int = 12

    /// Minimum length of a "confirmed echo" run. Runs of N or more
    /// consecutive mic segments matching nearby system segments are
    /// dropped wholesale; shorter runs are treated as ambiguous
    /// (possibly legitimate quoting) and kept.
    private static let confirmedEchoRunLength: Int = 3

    /// Apply the dedup filter to a merged segment list. Returns the
    /// segments to write to disk / show in transcript markdown. The
    /// input is expected to be the union of mic + system segments
    /// sorted by `startedAt`, exactly as `RecordingSession.segments`
    /// produces it.
    ///
    /// Returned list preserves order and identity for kept segments;
    /// dropped echoes are simply absent from the output.
    static func filter(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        // Index system segments by start time for O(log n) window
        // lookups. We pre-normalize the system text once per
        // segment — Levenshtein on normalized text is cheaper than
        // on raw, and we'll potentially compare it against many mic
        // segments. The window scan during pass 1 walks
        // a small slice so the overall cost stays linear in
        // segment count, not quadratic.
        let systemSegments = segments
            .filter { $0.source == .systemAudio }
            .sorted { $0.startSec < $1.startSec }
        let systemNorm: [String] = systemSegments.map { normalize($0.text) }

        // Pass 1: mark every mic segment as echo / not-echo.
        // We build a parallel `isEcho` array because mic segments
        // are intermixed with system segments in the input order;
        // walking them once + storing the verdict lets pass 2 see
        // the sequential pattern without re-scanning.
        var verdict: [Bool] = Array(repeating: false, count: segments.count)
        for (idx, seg) in segments.enumerated() {
            guard seg.source == .microphone else { continue }
            let micText = normalize(seg.text)
            guard !micText.isEmpty else { continue }
            verdict[idx] = matchesAnyNearby(
                micText: micText,
                micStart: seg.startSec,
                systemSegments: systemSegments,
                systemNorm: systemNorm
            )
        }

        // Pass 2: collapse the verdict array into kept / dropped
        // decisions. Echo runs of length ≥ `confirmedEchoRunLength`
        // are dropped wholesale (high confidence). Shorter runs are
        // kept (ambiguous — could be the user quoting the other
        // side once, which is a legitimate transcript artifact).
        // System segments and non-echo mic segments are always
        // kept.
        var keep: [Bool] = Array(repeating: true, count: segments.count)
        var i = 0
        while i < segments.count {
            // Find next echo-run boundary.
            guard segments[i].source == .microphone, verdict[i] else {
                i += 1
                continue
            }
            // We're at the start of a candidate echo run. Walk
            // forward through consecutive mic segments and count
            // how many are flagged as echoes. Non-mic segments
            // (system audio interleaved) don't break the run —
            // they're orthogonal sources.
            let runStart = i
            var runEnd = i
            var micRunLen = 1
            var j = i + 1
            while j < segments.count {
                let s = segments[j]
                if s.source == .microphone {
                    if verdict[j] {
                        runEnd = j
                        micRunLen += 1
                        j += 1
                    } else {
                        break  // mic-side non-echo breaks the run
                    }
                } else {
                    // System-audio interleaved — skip past, doesn't
                    // count toward run length but doesn't break it.
                    j += 1
                }
            }
            if micRunLen >= confirmedEchoRunLength {
                // Confirmed echo block — drop all flagged mic
                // segments inside [runStart, runEnd]. Non-mic
                // segments in that range are preserved.
                for k in runStart...runEnd where verdict[k] && segments[k].source == .microphone {
                    keep[k] = false
                }
            }
            i = j
        }

        return zip(segments, keep)
            .compactMap { $1 ? $0 : nil }
    }

    // MARK: - Internals

    /// Walks the sorted `systemSegments` and returns true if any
    /// system segment within ±matchWindowSec of `micStart` has text
    /// matching `micText` per the similarity + length-ratio rules.
    /// Linear in the size of the window slice (typically ≤5 segments)
    /// rather than total system segment count.
    private static func matchesAnyNearby(
        micText: String,
        micStart: Double,
        systemSegments: [TranscriptSegment],
        systemNorm: [String]
    ) -> Bool {
        // Binary search for the first system segment whose start is
        // within the window. lowerBound = micStart - window.
        let lowerBound = micStart - matchWindowSec
        let upperBound = micStart + matchWindowSec
        guard let startIdx = firstIndex(systemSegments, atOrAfter: lowerBound) else {
            return false
        }
        var idx = startIdx
        while idx < systemSegments.count, systemSegments[idx].startSec <= upperBound {
            let sysText = systemNorm[idx]
            if isEchoMatch(micText: micText, sysText: sysText) {
                return true
            }
            idx += 1
        }
        return false
    }

    /// First index in `segments` whose `startSec` is ≥ `target`.
    /// Standard binary-search lower-bound; returns nil if all
    /// segments precede the target.
    private static func firstIndex(
        _ segments: [TranscriptSegment],
        atOrAfter target: Double
    ) -> Int? {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].startSec < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo < segments.count ? lo : nil
    }

    /// Both texts already normalized via `normalize(_:)`. Checks
    /// the length-ratio gate first (cheap O(1) reject) before
    /// running Levenshtein (O(n*m)).
    private static func isEchoMatch(micText: String, sysText: String) -> Bool {
        guard !sysText.isEmpty, !micText.isEmpty else { return false }
        let micLen = Double(micText.count)
        let sysLen = Double(sysText.count)

        // Path 1 — near-equal length + high similarity. Catches the same
        // utterance transcribed slightly differently on each stream
        // ("Нова Медиа" vs "Ново-Медиа") when both streams chunked it
        // the same way.
        let ratio = abs(micLen - sysLen) / max(micLen, sysLen)
        if ratio <= lengthRatioTolerance {
            let dist = Double(levenshtein(micText, sysText))
            let similarity = 1.0 - (dist / max(micLen, sysLen))
            if similarity >= similarityThreshold { return true }
        }

        // Path 2 — containment. The common real case: one stream emits
        // the whole sentence as one segment while the other splits it
        // into chunks, so each chunk is a substring of the long segment
        // but the ±20% length gate (Path 1) rejects it. If the shorter
        // normalized text is substantial (≥ minContainmentLen) and is a
        // substring of the longer, treat as echo. The ≥3-consecutive run
        // rule in `filter` still protects an isolated legitimate quote.
        let (shorter, longer) = micLen <= sysLen
            ? (micText, sysText)
            : (sysText, micText)
        if shorter.count >= minContainmentLen, longer.contains(shorter) {
            return true
        }
        return false
    }

    /// Normalize for similarity comparison: lowercase, drop
    /// non-letter/digit punctuation, collapse whitespace. Whisper
    /// emits slightly different punctuation across passes ("Хорошо."
    /// on mic vs "Хорошо" on system, "ё" vs "е" inconsistencies)
    /// and we don't want those to break the match.
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var scalars: [Character] = []
        var lastWasSpace = false
        for c in lowered {
            if c.isLetter || c.isNumber {
                scalars.append(c)
                lastWasSpace = false
            } else if c.isWhitespace {
                if !lastWasSpace, !scalars.isEmpty {
                    scalars.append(" ")
                    lastWasSpace = true
                }
            }
            // Punctuation/symbols dropped entirely.
        }
        // Trim trailing space if any.
        while scalars.last == " " { scalars.removeLast() }
        return String(scalars)
    }

    /// Standard iterative Levenshtein distance with O(min(m,n)) extra
    /// memory. Called on short normalized strings (typical Whisper
    /// segment 5-30 words = 30-200 chars), so the O(n*m) cost is
    /// negligible against the ±2s window scan.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
