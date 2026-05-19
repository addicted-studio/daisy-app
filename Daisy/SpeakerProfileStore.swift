//
//  SpeakerProfileStore.swift
//  Daisy
//
//  Disk-backed registry of `SpeakerProfile`s. One JSON file per
//  profile under
//  `<container>/Application Support/Daisy/SpeakerProfiles/<uuid>.json`.
//  Loaded into memory on first access and kept hot for the life of
//  the app — there's typically only a handful of profiles, the
//  whole set is well under 100 KB.
//
//  Matching contract: given a new cluster centroid (256-d L2-
//  normalized), `findMatch(for:)` returns the highest-similarity
//  stored profile IF its cosine similarity exceeds `matchThreshold`.
//  Threshold tuned conservative (0.65) — false-positive ("auto-
//  named wrong person") is worse UX than false-negative ("user has
//  to rename manually again").
//
//  Privacy: profiles never leave the Mac. `forgetAll()` wipes the
//  directory; `forget(_:)` removes one. Both are exposed in
//  Settings for explicit user control.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class SpeakerProfileStore {
    static let shared = SpeakerProfileStore()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SpeakerProfiles")

    /// Cosine similarity threshold for "same speaker" matching.
    /// wespeaker_v2 same-speaker pairs typically score 0.7+, distinct
    /// pairs <0.5; 0.65 leaves a 0.05 safety margin against false
    /// positives. Tunable per-user in a future Settings row if we
    /// see real-world drift.
    static let matchThreshold: Float = 0.65

    /// All known profiles, keyed by UUID. Observable so any UI that
    /// renders the profile list (Settings, SessionDetailView's
    /// "Name the speakers" card) re-renders on add/rename/delete.
    private(set) var profiles: [UUID: SpeakerProfile] = [:]

    private let dirURL: URL
    private var loaded = false

    private init() {
        // Container's Application Support — sandboxed, encrypted at
        // rest by macOS FileVault, survives app re-installs (unless
        // user explicitly resets the container).
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        self.dirURL = appSupport
            .appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent("SpeakerProfiles", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Lazy load on first access. Idempotent. Safe to call from
    /// view body / init paths.
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        do {
            try FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true
            )
        } catch {
            log.error("Couldn't create profile dir: \(error.localizedDescription, privacy: .public)")
            return
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var loaded: [UUID: SpeakerProfile] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let profile = try? decoder.decode(SpeakerProfile.self, from: data) else {
                log.warning("Skipped malformed profile at \(url.lastPathComponent, privacy: .public)")
                continue
            }
            loaded[profile.id] = profile
        }
        profiles = loaded
        log.info("Loaded \(loaded.count, privacy: .public) speaker profile(s)")
    }

    // MARK: - Match

    /// Returns the best-matching profile for a cluster centroid, OR
    /// nil if no stored profile scores above the threshold. Caller
    /// (RecordingSession) uses this to pre-fill `daisy_speaker_map`
    /// on save so the user opens the transcript and sees "Alex" /
    /// "Mom" instead of "Remote A".
    func findMatch(for embedding: [Float]) -> SpeakerProfile? {
        ensureLoaded()
        guard !embedding.isEmpty else { return nil }
        var best: (profile: SpeakerProfile, score: Float)?
        for profile in profiles.values {
            let score = speakerCosineSimilarity(embedding, profile.embedding)
            if score > Self.matchThreshold, best == nil || score > best!.score {
                best = (profile, score)
            }
        }
        return best?.profile
    }

    /// Bump a matched profile's `lastSeenAt` + `sessionCount`. Called
    /// by RecordingSession after a successful auto-match so the
    /// management UI shows accurate "last heard" timestamps.
    func recordMatch(profileID: UUID) {
        ensureLoaded()
        guard var profile = profiles[profileID] else { return }
        profile.lastSeenAt = Date()
        profile.sessionCount += 1
        profiles[profileID] = profile
        write(profile)
    }

    // MARK: - Create / update

    /// Save or update a profile. Called by SessionDetailView when
    /// the user manually types a name into the "Name the speakers"
    /// card — the matching centroid embedding (from the session's
    /// `speakers.json` sidecar) is paired with the user-typed name
    /// to either reinforce an existing match or create a new
    /// profile.
    ///
    /// Heuristic: if `embedding` matches an existing profile under
    /// a DIFFERENT name, prefer renaming the existing profile over
    /// creating a duplicate — same person under two names is a
    /// data integrity bug we want to avoid.
    @discardableResult
    func upsert(name: String, embedding: [Float]) -> SpeakerProfile {
        ensureLoaded()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // 1. If embedding matches an existing profile → rename
        //    that profile (don't duplicate).
        if let match = findMatch(for: embedding) {
            var updated = match
            if updated.name != trimmed {
                updated.name = trimmed
            }
            updated.lastSeenAt = Date()
            profiles[updated.id] = updated
            write(updated)
            // Speaker name is PII the user typed — keep .private so
            // real names ("John", "Maria") don't end up in the
            // unified system log. Profile ID stays public — it's an
            // opaque UUID with no inherent identity.
            log.info("Renamed existing profile \(updated.id, privacy: .public) → \(trimmed, privacy: .private)")
            return updated
        }
        // 2. If a profile already has this name → update its
        //    embedding (re-enroll). Lets users explicitly re-enroll
        //    by typing the same name on a new speaker — e.g.
        //    they're on a different mic that changed timbre.
        if let existing = profiles.values.first(where: {
            $0.name.lowercased() == trimmed.lowercased()
        }) {
            var updated = existing
            updated.embedding = embedding
            updated.lastSeenAt = Date()
            updated.sessionCount += 1
            profiles[updated.id] = updated
            write(updated)
            log.info("Re-enrolled profile for \(trimmed, privacy: .private)")
            return updated
        }
        // 3. Fresh profile.
        let new = SpeakerProfile(name: trimmed, embedding: embedding)
        profiles[new.id] = new
        write(new)
        log.info("Created profile for \(trimmed, privacy: .private)")
        return new
    }

    // MARK: - Forget

    /// Remove one profile from disk + memory.
    func forget(_ id: UUID) {
        ensureLoaded()
        profiles.removeValue(forKey: id)
        let url = dirURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Nuclear option — wipe every profile. Exposed in Settings.
    func forgetAll() {
        ensureLoaded()
        for id in profiles.keys {
            let url = dirURL.appendingPathComponent("\(id.uuidString).json")
            try? FileManager.default.removeItem(at: url)
        }
        profiles.removeAll()
        log.info("Forgot all speaker profiles")
    }

    // MARK: - Sorted view for UI

    /// Profiles ordered by most-recently-seen, descending. Settings
    /// list renders in this order so active speakers float to the
    /// top, dormant ones sink.
    var profilesByRecent: [SpeakerProfile] {
        ensureLoaded()
        return profiles.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    // MARK: - Disk write

    private func write(_ profile: SpeakerProfile) {
        let url = dirURL.appendingPathComponent("\(profile.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("Couldn't persist profile \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
