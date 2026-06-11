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
#if canImport(FluidAudio)
import FluidAudio
#endif

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
    #if canImport(FluidAudio)
    /// Silero VAD wrapper, loaded lazily alongside Whisper. Used as a
    /// pre-pass on every `transcribe` call to gate out non-speech
    /// audio before it reaches Whisper — the biggest single lever
    /// against ambient-noise hallucinations (whisper.cpp #2286,
    /// faster-whisper #843). Nil while loading or if load failed;
    /// `transcribe` falls back to full-buffer Whisper in that case so
    /// the user never sees a hard error from VAD.
    @ObservationIgnored
    private var vadBox: VadManagerBox?
    @ObservationIgnored
    private var vadLoadTask: Task<Void, Never>?
    #endif

    // In-actor serialization for transcribe — WhisperKit isn't thread-safe
    // for simultaneous transcribes.
    @ObservationIgnored
    private var isBusy = false
    @ObservationIgnored
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// One-time post-load warm-up guard — see `warmUpIfNeeded()`.
    @ObservationIgnored
    private var didWarmUp = false

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

    /// Conservative lower bound for the disk space we need before
    /// kicking off a fresh model download. The largest variant
    /// users typically pick (`large-v3-v20240930_626MB`) lands as
    /// ~1.5 GB of CoreML artefacts on disk after unpack; smaller
    /// variants are well under this. 2 GB free leaves headroom
    /// for HuggingFace's temp files, swap pressure, and a
    /// margin for a recording or two right after the download
    /// completes. Better to refuse early with a clear message
    /// than to wedge at "100% downloaded" because the temp file
    /// couldn't be moved into place.
    private static let minRequiredDiskBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Two-phase load: first explicit download (with progress) then
    /// CoreML init. Splitting lets the UI show a real progress bar
    /// during the 70 MB – 1.5 GB download.
    private func performLoad() async {
        let variant = modelID
        let repo = "argmaxinc/whisperkit-coreml"

        // Phase 0 — disk space preflight. Spinning on
        // `.downloading(progress: 1.0)` because the destination
        // volume is full is the worst possible failure mode: no
        // error, no recovery, the user thinks the model is
        // "loading forever". Refuse early with a concrete number
        // the user can act on.
        if let available = Self.availableDiskBytes(),
           available < Self.minRequiredDiskBytes {
            let neededGB = Double(Self.minRequiredDiskBytes) / 1_073_741_824.0
            let haveGB = Double(available) / 1_073_741_824.0
            let msg = String(
                format: "Not enough disk space to download the transcription model — need %.1f GB free, only %.2f GB available. Free some space and try again.",
                neededGB, haveGB
            )
            log.error("Whisper download aborted — disk too full (\(available, privacy: .public) bytes free)")
            state = .failed(msg)
            return
        }

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

        // Phase 3 — load Silero VAD in the background. Non-blocking:
        // Whisper is already .ready, transcribe() will run without
        // VAD until the first VAD load completes (and the first
        // transcribe after that picks it up). This avoids stalling
        // the "ready to record" UX on the Silero CoreML download.
        ensureVADLoadStarted()

        // Phase 4 — one-time warm-up decode (non-blocking). The first
        // real transcribe after a cold load pays CoreML/ANE function
        // specialization + tokenizer init on top of the actual decode;
        // for dictation that cost lands on the user's first hotkey
        // release. Pay it here instead, against 1 s of silence.
        warmUpIfNeeded()
    }

    /// Run a single throwaway `.lite` pass over 1 s of silence so the
    /// first user-visible transcribe doesn't pay cold-start costs.
    /// Fire-and-forget: the spawning Task returns immediately and the
    /// engine's in-actor semaphore (acquire/release inside
    /// `transcribe`) serializes the warm-up against any real pass that
    /// arrives first — a real caller queued behind it waits one short
    /// silence decode at most. Idempotent via `didWarmUp`.
    private func warmUpIfNeeded() {
        guard case .ready = state, !didWarmUp else { return }
        didWarmUp = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let t0 = Date()
            // 1 s of zeros at Whisper's 16 kHz input rate. NB: if the
            // Silero VAD finished loading first it will gate this
            // buffer to "no speech" and skip the Whisper decode — in
            // the common cold-start case VAD is still downloading/
            // loading (phase 3 above), so the pass takes the
            // full-buffer path and warms the decoder for real.
            let silence = [Float](repeating: 0, count: 16_000)
            do {
                _ = try await self.transcribe(samples: silence, language: nil, profile: .lite)
                self.log.info("Whisper warm-up pass done in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            } catch {
                // Non-fatal by design — warm-up is purely an optimization.
                self.log.info("Whisper warm-up pass failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if canImport(FluidAudio)
    /// Kick off Silero VAD model load if it isn't already loading /
    /// loaded. Idempotent. Runs detached so it doesn't extend the
    /// visible "loading Whisper" phase the user already waits through.
    private func ensureVADLoadStarted() {
        if vadBox != nil || vadLoadTask != nil { return }
        vadLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Default threshold 0.85 is the FluidAudio recommended
                // value; lower (e.g. 0.5) would let more borderline
                // chunks through and partially undo what we're trying
                // to gain here. We can revisit if we see real speech
                // being clipped.
                let cfg = VadConfig(defaultThreshold: 0.85)
                // Offline-first: cached Silero loads with FluidAudio's
                // network hard-blocked; first run opens an explicit
                // download window via the guard.
                let vad: VadManager
                do {
                    vad = try await VadManager(config: cfg)
                } catch let error where FluidAudioNetworkGuard.isOfflineRejection(error) {
                    vad = try await FluidAudioNetworkGuard.withDownloadsAllowed("Silero VAD") {
                        try await VadManager(config: cfg)
                    }
                }
                self.vadBox = VadManagerBox(vad)
                self.log.info("Silero VAD loaded")
            } catch {
                self.log.error("Silero VAD load failed (continuing without VAD): \(error.localizedDescription, privacy: .public)")
            }
            self.vadLoadTask = nil
        }
    }
    #else
    private func ensureVADLoadStarted() {}
    #endif

    /// Available bytes on the volume that backs the user's home
    /// directory — same volume HuggingFace stages downloads into
    /// (~/Library/Caches). `volumeAvailableCapacityForImportantUsage`
    /// is Apple's recommended key for "can I write a big file
    /// here?"; it respects purgeable-space accounting (TimeMachine
    /// snapshots, iCloud caches) better than the raw free-bytes
    /// number. Returns nil if the lookup fails — caller treats
    /// that as "no preflight" rather than aborting.
    nonisolated private static func availableDiskBytes() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
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

    // MARK: - Cache inspection

    /// One entry per downloaded Whisper model variant — folder URL,
    /// the short variant id (e.g. `large-v3-v20240930_626MB`), and
    /// the recursive byte size on disk. Used by the Transcription
    /// settings tab to show "Models cached: X.X GB" and to offer a
    /// one-click cleanup of variants the user isn't using.
    struct CachedModel: Hashable, Sendable {
        let variant: String
        let url: URL
        let sizeBytes: Int64
    }

    /// Enumerate downloaded model folders under
    /// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`.
    /// Sandboxed apps see that as their container's Documents
    /// directory — same place WhisperKit.download writes to.
    /// Returns an empty array if the folder doesn't exist yet
    /// (no models ever downloaded).
    nonisolated static func cachedModels() -> [CachedModel] {
        guard let root = whisperCacheRoot() else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        // WhisperKit prepends "openai_whisper-" to every variant
        // folder. HuggingFace's downloader also stashes sibling
        // bookkeeping directories at the same level — `.locks`,
        // `.cache`, occasional tokenizer bundles — which previously
        // got counted as "models on disk" (user saw `2 models` after
        // downloading one). Require the prefix so only real model
        // folders make it into the cache report.
        let prefix = "openai_whisper-"
        return entries.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            let folderName = url.lastPathComponent
            guard folderName.hasPrefix(prefix) else { return nil }
            let variant = String(folderName.dropFirst(prefix.count))
            return CachedModel(
                variant: variant,
                url: url,
                sizeBytes: directorySize(at: url)
            )
        }
    }

    /// Total bytes consumed by every downloaded Whisper variant on
    /// disk. Sum of `cachedModels().sizeBytes`. Convenience wrapper
    /// so the UI doesn't have to fold the list itself.
    nonisolated static func totalCacheSizeBytes() -> Int64 {
        cachedModels().reduce(0) { $0 + $1.sizeBytes }
    }

    /// Remove every downloaded model variant except the one the user
    /// currently has active. Idempotent — safe to call when there's
    /// only one cached variant (it'll just no-op). Returns the freed
    /// bytes for caller-side reporting.
    @MainActor
    func removeUnusedModels() async -> Int64 {
        let active = modelID
        let cached = Self.cachedModels()
        let fm = FileManager.default
        var freed: Int64 = 0
        for model in cached where model.variant != active {
            do {
                try fm.removeItem(at: model.url)
                freed += model.sizeBytes
                log.info("Removed cached Whisper model \(model.variant, privacy: .public) (\(model.sizeBytes) bytes)")
            } catch {
                log.error("Failed to remove \(model.variant, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return freed
    }

    /// Root directory of WhisperKit's model cache inside the sandbox.
    /// Mirrors WhisperKit's own internal path resolution — kept
    /// in one place so a future Argmax-side change to the layout is
    /// a one-spot fix here.
    nonisolated private static func whisperCacheRoot() -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// Recursive directory size in bytes. Walks the enumerator
    /// once; cheaper than `du`-shelling out for sub-1GB trees.
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
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

    /// Decode cost profile for a transcription pass. `.lite` trims the
    /// expensive knobs (4 ANE workers, greedy `topK: 1`, no temperature
    /// fallbacks) for throwaway live passes; `.full` is the quality path
    /// used for the meeting/voice-note final pass and for the Full live
    /// tier. `.dictationFinal` sits in between: same trimmed search
    /// width as `.lite`, but ONE temperature-fallback retry — the
    /// dictation final pass pastes its output verbatim with no later
    /// cleanup pass, so a garbled first decode deserves a second
    /// chance, while a `.full`-width search on a few seconds of speech
    /// is pure release→paste latency. The anti-hallucination thresholds
    /// + VAD are identical across all profiles — only the search width /
    /// retry / worker counts change.
    enum DecodeProfile: Sendable, Equatable {
        case full
        case lite
        case dictationFinal

        /// Temperature-fallback retries when the anti-hallucination
        /// filters trip. `.full` keeps the historical 3 (see the
        /// trade-off note in `transcribe`).
        var temperatureFallbackCount: Int {
            switch self {
            case .full:           return 3
            case .dictationFinal: return 1
            case .lite:           return 0
            }
        }
        /// Token search width — greedy everywhere off the quality path.
        var topK: Int { self == .full ? 5 : 1 }
        /// ANE worker count — 16 only for the full-quality pass; 16 on
        /// a short span just burst-overheats the ANE (see `.lite` note).
        var concurrentWorkerCount: Int { self == .full ? 16 : 4 }
    }

    /// Run a transcription pass against 16 kHz mono Float samples.
    /// Multiple callers are serialized. `language` is a two-letter ISO
    /// code ("en", "ru") or nil for auto-detect. `profile` trades decode
    /// cost for quality — see `DecodeProfile`.
    func transcribe(samples: [Float], language: String?, profile: DecodeProfile = .full) async throws -> [WhisperSegment] {
        await acquireSlot()
        defer { releaseSlot() }

        // Cooperative cancellation — bail before any heavy work if the
        // calling task was cancelled while queued behind another pass
        // (dictation stop cancels the in-flight live window; a rotated
        // session cancels its finalize task). The `defer` above
        // releases the slot to the next waiter.
        try Task.checkCancellation()

        await ensureLoaded()
        guard let box = kitBox else { throw WhisperEngineError.notReady }

        // Per-pass timing instrumentation (privacy-safe: durations and
        // counts only, never transcript content). Attributes dictation
        // release→paste latency between the Silero VAD pre-pass and
        // the Whisper decode itself.
        let passStart = Date()

        // Anti-hallucination knobs. Whisper has a well-documented
        // failure mode where silence or non-speech ambient sound
        // (fans, packing tape, HVAC) gets decoded as text from its
        // YouTube training data — "Thanks for watching!", "ご視聴
        // ありがとうございました", "Спасибо за внимание", or
        // short single tokens like "so", "you", "はい".
        //
        // Thresholds tuned 2026-05-18 after QA feedback that
        // ambient noise was still producing "so" / "はい" leaks
        // through the 0.55 / -1.0 baseline. Tier-1 values
        // cross-validated from whisper.cpp, faster-whisper and
        // WhisperKit community issues — see CHANGELOG for citations.
        //
        //   noSpeechThreshold       — segment dropped if Whisper's
        //                             own "is this non-speech?" prob
        //                             exceeds this. Lower = stricter.
        //                             Default 0.6 → 0.55 → 0.4 here.
        //                             0.4 catches single-token leaks.
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
        //                             filters trigger. Kept at 3 — see
        //                             the trade-off note in faster-whisper
        //                             #621 (fallbacks can _increase_
        //                             hallucinations on pure noise);
        //                             revisit if the post-filter below
        //                             stops being enough.
        //
        // Note on language locking: if the caller pinned a language
        // (`language != nil`) we never auto-detect, which alone kills
        // a class of hallucinations where Whisper drifts into the
        // wrong language on noise (English speaker → spurious
        // "ありがとうございました"). `Transcriber` snaps `language`
        // to the locked locale after the first few confident segments.
        // Lite live passes trade search width for speed/energy: 4 ANE
        // workers instead of the macOS default 16 (16 on a short VAD span
        // every few seconds just burst-overheats the ANE), greedy
        // `topK: 1`, and no temperature fallbacks. The anti-hallucination
        // thresholds + VAD are kept identical — the meeting final pass
        // on Stop (`.full`) cleans up anything Lite missed; dictation's
        // inline final pass uses `.dictationFinal` (lite width, one
        // fallback retry) since its output is pasted verbatim. All knob
        // values live on `DecodeProfile`.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: profile.temperatureFallbackCount,
            topK: profile.topK,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.4,
            concurrentWorkerCount: profile.concurrentWorkerCount,
            chunkingStrategy: .vad
        )

        // ── VAD pre-pass ───────────────────────────────────────────
        // Carve `samples` into speech-only spans before handing it
        // to Whisper. This is the single biggest anti-hallucination
        // lever (see the multi-source justification at the top of
        // this method). If VAD isn't loaded yet (still downloading
        // its CoreML model, or first transcribe of the session) we
        // fall through to the legacy full-buffer Whisper path.
        let vadStart = Date()
        let speechSpans: [SpeechSpan] = await runVADPrepass(samples: samples)
        let vadMs = Int(Date().timeIntervalSince(vadStart) * 1000)

        // Run Whisper per speech span (or once on the whole buffer
        // if VAD wasn't available). Per-span timings are translated
        // back into the original-buffer coordinate space so the
        // Transcriber doesn't notice the VAD slicing.
        var allRaw: [(spanOffsetSec: Double, segs: [TranscriptionSegment])] = []
        if speechSpans.isEmpty {
            // VAD says "no speech" — skip Whisper entirely. This is
            // the desired behaviour for ambient-noise-only buffers:
            // empty result, no hallucinated text, no compute spent.
            log.info("Whisper pass: vad=\(vadMs, privacy: .public)ms decode=0ms (no speech) audio=\(samples.count, privacy: .public) samples")
            return []
        }
        let decodeStart = Date()
        for span in speechSpans {
            // Cooperative cancellation point between spans — a
            // cancelled live pass exits here instead of decoding the
            // remaining spans; `defer` releases the engine slot.
            try Task.checkCancellation()
            let chunk: [Float]
            let offsetSec: Double
            if span.isFullBuffer {
                chunk = samples
                offsetSec = 0
            } else {
                let lo = max(0, min(samples.count, span.startSample))
                let hi = max(lo, min(samples.count, span.endSample))
                guard hi > lo else { continue }
                chunk = Array(samples[lo..<hi])
                offsetSec = Double(lo) / Self.audioSampleRate
            }
            // Skip pathologically short chunks — Whisper produces
            // garbage on sub-200ms inputs even with our thresholds.
            if Double(chunk.count) / Self.audioSampleRate < 0.20 { continue }
            let results = try await box.kit.transcribe(audioArray: chunk, decodeOptions: options)
            for result in results {
                allRaw.append((offsetSec, result.segments))
            }
        }
        let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)
        let rawSegmentCount = allRaw.reduce(0) { $0 + $1.segs.count }
        log.info("Whisper pass: vad=\(vadMs, privacy: .public)ms decode=\(decodeMs, privacy: .public)ms total=\(Int(Date().timeIntervalSince(passStart) * 1000), privacy: .public)ms spans=\(speechSpans.count, privacy: .public) rawSegments=\(rawSegmentCount, privacy: .public) audio=\(samples.count, privacy: .public) samples")

        // Post-filter pipeline. Each rule kills a distinct class of
        // hallucination observed in QA; the comments name the class.
        var previousText: String?
        return allRaw.flatMap { (offsetSec, segs) in
            segs.compactMap { seg -> WhisperSegment? in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                // (1) Known YouTube-training artefacts (full phrases).
                if Self.isKnownHallucination(text) { return nil }

                // (2) Confidence filter. Hallucinated short tokens
                // ("so", "はい", "you") almost always score below
                // -0.7 avg log-prob. A blanket -0.8 cut kills the
                // worst offenders without removing real-but-noisy
                // speech (which typically scores -0.4 to -0.7).
                if seg.avgLogprob < -0.8 { return nil }

                // (3) Short-utterance + middling-confidence cut.
                // 1–2 word segments with avgLogprob below -0.6 are
                // suspect — real short answers ("yes", "ok", "да")
                // score higher because Whisper's prior is strong on
                // them. This catches the residual single-token leaks
                // (2)'s harder threshold lets through.
                let wordCount = text
                    .split(whereSeparator: { $0.isWhitespace })
                    .count
                if wordCount <= 2 && seg.avgLogprob < -0.6 { return nil }

                // (4) Adjacent-duplicate collapse. Only fires when
                // the text is long enough that a real repeat is
                // implausible (avoids killing "yes, yes" / "ok ok").
                if text.count >= 6, text == previousText { return nil }
                previousText = text

                // Translate per-span timings back into the original
                // buffer's coordinate space (`offsetSec` is 0 when
                // VAD wasn't used or returned a full-buffer span).
                return WhisperSegment(
                    start: offsetSec + Double(seg.start),
                    end: offsetSec + Double(seg.end),
                    text: text
                )
            }
        }
    }

    // MARK: - VAD pre-pass

    /// What `runVADPrepass` returns: either concrete sample ranges
    /// inside the input buffer (when VAD found speech) or a sentinel
    /// "use the whole buffer" span (when VAD isn't loaded / errored).
    /// An empty array means VAD ran and found no speech.
    private struct SpeechSpan {
        let startSample: Int
        let endSample: Int
        let isFullBuffer: Bool

        static let fullBuffer = SpeechSpan(startSample: 0, endSample: 0, isFullBuffer: true)
    }

    /// Run Silero VAD on the input buffer and return the speech-only
    /// spans. Returns `[.fullBuffer]` (single sentinel) if VAD isn't
    /// available — that preserves v1.0 behaviour as a graceful
    /// fallback. Returns `[]` if VAD ran but found no speech.
    private func runVADPrepass(samples: [Float]) async -> [SpeechSpan] {
        #if canImport(FluidAudio)
        guard let vadBox else {
            // VAD still loading or load failed — fall back to
            // legacy full-buffer Whisper path.
            return [.fullBuffer]
        }
        // FluidAudio's VadSegmentationConfig knobs are in seconds
        // (TimeInterval). Defaults below cross-validated from the
        // Silero Python community ranges, adjusted for meeting
        // capture: a slightly more permissive minSpeechDuration so
        // we don't drop short backchannels ("yes"), a longer
        // minSilenceDuration so we don't fragment phrasing across
        // breath pauses, and modest padding so word edges aren't
        // shaved off by the gate.
        var cfg = VadSegmentationConfig.default
        cfg.minSpeechDuration  = 0.25     // 250 ms
        cfg.minSilenceDuration = 0.50     // 500 ms
        cfg.speechPadding      = 0.20     // 200 ms each side
        cfg.maxSpeechDuration  = 14.0     // Whisper-friendly cap

        do {
            let segments = try await vadBox.vad.segmentSpeech(samples, config: cfg)
            return segments.map { vs in
                let start = Int(vs.startTime * Self.audioSampleRate)
                let end   = Int(vs.endTime   * Self.audioSampleRate)
                return SpeechSpan(startSample: start, endSample: end, isFullBuffer: false)
            }
        } catch {
            log.error("VAD segmentSpeech failed (using full buffer): \(error.localizedDescription, privacy: .public)")
            return [.fullBuffer]
        }
        #else
        return [.fullBuffer]
        #endif
    }

    nonisolated private static let audioSampleRate: Double = 16_000

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

#if canImport(FluidAudio)
/// Sendable wrapper around the actor-isolated `VadManager` so we can
/// stash it as a property on `WhisperEngine` (also actor-isolated)
/// without Sendable complaints. `VadManager` itself is already an
/// actor, so its API stays safe across actor hops.
final class VadManagerBox: @unchecked Sendable {
    let vad: VadManager
    init(_ vad: VadManager) { self.vad = vad }
}
#endif

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
