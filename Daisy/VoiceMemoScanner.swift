//
//  VoiceMemoScanner.swift
//  Daisy
//
//  Drives Voice Memos import: a once-a-day (+ on-launch) scan that
//  transcribes NEW recordings into `<transcripts folder>/Voice Memos/`.
//  Opt-in via Settings → Recording. Dedup by memo id (persisted), so
//  nothing is transcribed twice; originals are never touched.
//
//  Scheduling model (the user asked for "раз в день, и всё"): on launch
//  we run one delayed scan and arm a 24 h repeating timer. The toggle
//  flipping ON also kicks an immediate scan. "Process existing" runs a
//  one-shot backfill over the whole library.
//
//  Auto-scans only import memos recorded AFTER the feature was switched
//  on (baseline date), so turning it on doesn't suddenly transcribe a
//  500-memo backlog. The "Process existing" button lifts that gate.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class VoiceMemoScanner {
    static let shared = VoiceMemoScanner()

    /// Subfolder name created inside the user's transcripts/sessions
    /// folder for voice-memo notes.
    static let destSubfolder = "Voice Memos"

    // Observable status for the Settings UI.
    private(set) var isScanning = false
    private(set) var importedThisRun = 0
    private(set) var lastStatus: VoiceMemoLibrary.AccessStatus = .ok

    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "VoiceMemos")
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?

    private static let k_processed = "daisy.voiceMemos.processedIDs"
    private static let k_startDate = "daisy.voiceMemos.ingestStartDate"

    private init() {}

    // MARK: - Lifecycle

    /// Called once from app launch (`DaisyAppDelegate`). No-op unless
    /// the feature is enabled. Delays the first scan so it doesn't
    /// fight first-paint, then arms the daily timer.
    func start(enabled: Bool) {
        guard enabled else { return }
        // Make sure a baseline date exists for installs that had the
        // toggle on before this field was introduced.
        if defaults.object(forKey: Self.k_startDate) == nil {
            defaults.set(Date(), forKey: Self.k_startDate)
        }
        scheduleDaily()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            await scanNow()
        }
    }

    /// Called from the Settings toggle.
    func onToggle(enabled: Bool) {
        if enabled {
            if defaults.object(forKey: Self.k_startDate) == nil {
                defaults.set(Date(), forKey: Self.k_startDate)
            }
            scheduleDaily()
            Task { await scanNow() }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func scheduleDaily() {
        guard timer == nil else { return }
        // Created on the main actor → scheduled on the main run loop.
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scanNow() }
        }
    }

    // MARK: - Scan

    /// One scan pass. `backfill: true` also imports memos older than the
    /// enable date (the "Process existing" button); otherwise only memos
    /// recorded after the feature was switched on. Dedup by id means a
    /// memo is never transcribed twice regardless.
    func scanNow(backfill: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        importedThisRun = 0
        defer { isScanning = false }

        // Resolve destination inside the user's transcripts folder.
        guard let ticket = SessionsFolder.acquireBase() else {
            log.warning("Voice memo scan: no base folder acquired")
            return
        }
        defer { ticket.release() }
        let destDir = ticket.url.appendingPathComponent(Self.destSubfolder, isDirectory: true)

        switch VoiceMemoLibrary.enumerate() {
        case .failure(let status):
            lastStatus = status
            log.info("Voice memo scan halted: \(String(describing: status), privacy: .public)")
        case .success(let memos):
            lastStatus = .ok
            var processed = loadProcessed()
            let startDate = defaults.object(forKey: Self.k_startDate) as? Date ?? .distantPast
            let language = Self.whisperLanguage(
                from: defaults.string(forKey: "daisy.defaultTranscriptionLocale") ?? "auto"
            )

            for memo in memos {
                if processed.contains(memo.id) { continue }
                if !backfill && memo.recordedAt < startDate { continue }
                do {
                    _ = try await VoiceMemoIngestor.ingest(memo, into: destDir, language: language)
                    processed.insert(memo.id)
                    importedThisRun += 1
                    saveProcessed(processed) // incremental → crash-safe
                } catch {
                    // Leave unprocessed so it's retried next scan.
                    log.error("Voice memo ingest failed for \(memo.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
            if importedThisRun > 0 {
                log.info("Voice memo scan imported \(self.importedThisRun, privacy: .public) memo(s)")
            }
        }
    }

    // MARK: - Helpers

    /// Map the stored transcription-locale preference to Whisper's
    /// two-letter code, or nil for auto-detect.
    nonisolated static func whisperLanguage(from locale: String) -> String? {
        let l = locale.lowercased()
        if l.isEmpty || l == "auto" { return nil }
        let two = l.prefix(2)
        return two.isEmpty ? nil : String(two)
    }

    private func loadProcessed() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.k_processed) ?? [])
    }

    private func saveProcessed(_ set: Set<String>) {
        defaults.set(Array(set), forKey: Self.k_processed)
    }
}
