//
//  ScreenTextExtractor.swift
//  Daisy
//
//  On-device OCR over the screenshots captured during a recording, run
//  once at finalize time. Turns "what was shared on screen" — slides,
//  dashboards, docs — into searchable text folded into the transcript
//  and handed to the summarizer, so a metric on a slide or a date in a
//  doc becomes part of the record even if nobody read it aloud.
//
//  100% local: Apple's Vision framework, no network. The heavy pass runs
//  inside the already-detached post-Stop task, not on the main actor.
//
//  Deduplication is the whole trick: periodic capture produces many
//  near-identical frames of the same slide. We keep only frames whose
//  text meaningfully differs from the last kept one, so a slide shown
//  for ten minutes contributes one block, not sixty.
//

import Foundation
import Vision
import CoreGraphics
import ImageIO
import os

// `nonisolated` so the CPU-bound Vision pass runs OFF the main actor —
// finalize awaits it from a @MainActor context, so without this the
// synchronous OCR loop would block the UI (main-actor-by-default).
nonisolated enum ScreenTextExtractor {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "ScreenOCR")

    struct Result: Sendable {
        /// Markdown block ready to append under a "## Shared on screen"
        /// heading. Empty when nothing legible was captured.
        let markdown: String
        /// How many distinct screens survived dedup.
        let distinctScreens: Int
    }

    /// Minimum word-like characters for a frame to count as "has content"
    /// — filters idle desktop / menu-bar-only frames.
    private static let minContentChars = 16
    /// Jaccard similarity (word-set overlap) above which two consecutive
    /// frames are treated as the same screen.
    private static let dedupThreshold = 0.80
    /// Bounds so a pathological capture can't bloat the transcript.
    private static let maxCharsPerScreen = 900
    private static let maxTotalChars = 5_000
    private static let maxFrames = 400

    /// OCR every PNG in `directory` (sorted by name = capture order),
    /// dedup consecutive identical screens, and return a consolidated
    /// markdown block. Best-effort: unreadable frames are skipped, and a
    /// missing/empty directory yields an empty result.
    static func extract(from directory: URL) async -> Result {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return Result(markdown: "", distinctScreens: 0)
        }
        let pngs = entries
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxFrames)
        guard !pngs.isEmpty else { return Result(markdown: "", distinctScreens: 0) }

        var kept: [String] = []
        var lastTokens: Set<String> = []

        for url in pngs {
            guard let cg = loadCGImage(url) else { continue }
            let text = recognizeText(in: cg)
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard contentCharCount(normalized) >= minContentChars else { continue }

            let tokens = tokenSet(normalized)
            if !lastTokens.isEmpty, jaccard(tokens, lastTokens) >= dedupThreshold {
                // Same slide as the previous kept frame — skip. Keep the
                // longer of the two (a slide often reveals more text as it
                // animates in) so the retained block is the fullest one.
                if normalized.count > (kept.last?.count ?? 0) {
                    kept[kept.count - 1] = String(normalized.prefix(maxCharsPerScreen))
                }
                continue
            }

            kept.append(String(normalized.prefix(maxCharsPerScreen)))
            lastTokens = tokens

            if kept.reduce(0, { $0 + $1.count }) > maxTotalChars { break }
        }

        guard !kept.isEmpty else { return Result(markdown: "", distinctScreens: 0) }

        var md = ""
        for (i, block) in kept.enumerated() {
            md += "**Screen \(i + 1)**\n\n"
            md += block
            md += "\n\n"
        }
        log.info("Screen OCR: \(pngs.count, privacy: .public) frames → \(kept.count, privacy: .public) distinct screens")
        return Result(
            markdown: md.trimmingCharacters(in: .whitespacesAndNewlines),
            distinctScreens: kept.count
        )
    }

    // MARK: - Vision

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Synchronous Vision text recognition. Runs on the caller's (non-main)
    /// executor — finalize is already a detached task.
    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Multilingual (incl. Russian) without hardcoding a language list
        // — Vision picks per frame. Available macOS 13+.
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.error("Vision perform failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        // `request.results` is already typed `[VNRecognizedTextObservation]?`
        // on current SDKs — the old `as? [VNRecognizedTextObservation]`
        // downcast was a no-op (compiler warning). Nil-coalesce instead.
        let observations = request.results ?? []
        // Preserve reading order top-to-bottom: observations come sorted
        // by confidence, so re-sort by vertical position (Vision's origin
        // is bottom-left, so higher y = higher on screen).
        let lines = observations
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - Dedup helpers (pure)

    private static func contentCharCount(_ s: String) -> Int {
        s.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
    }

    private static func tokenSet(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
