//
//  SpeakerProfile.swift
//  Daisy
//
//  One persistent voice profile — Daisy's record of "this 256-d
//  embedding vector belongs to a person the user has named". Saved
//  to disk in the app's container and matched against new sessions
//  so users name a speaker once and Daisy auto-labels them in every
//  future meeting.
//
//  Privacy: the embedding is a biometric derivative — irreversible
//  (you cannot reconstruct the voice from it) but uniquely
//  identifying. Lives in the sandboxed container, NEVER leaves the
//  Mac, can be wiped from Settings → Speakers → Forget all.
//

import Foundation

struct SpeakerProfile: Codable, Identifiable, Sendable, Hashable {
    /// Stable UUID — used as both filename and in-memory dictionary
    /// key. Survives renames.
    let id: UUID
    /// Display name the user typed (e.g. "Alex", "Mom", "Customer:
    /// Sarah Chen"). Free-text, no validation beyond non-empty trim.
    var name: String
    /// 256-dim L2-normalized vector from FluidAudio's wespeaker_v2
    /// model. Cosine similarity ≥ matchThreshold against a new
    /// session's cluster centroid → "this is the same person".
    var embedding: [Float]
    /// When the profile was first created (user typed the name).
    let createdAt: Date
    /// Last time this profile matched a session — bumped on
    /// successful auto-match. Used to age-out stale profiles in the
    /// management UI ("haven't heard from this person in 6 months").
    var lastSeenAt: Date
    /// How many times Daisy has matched this profile in sessions.
    /// Display-only — gives the user a sense of which profiles are
    /// load-bearing vs one-offs.
    var sessionCount: Int

    init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        sessionCount: Int = 1
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.sessionCount = sessionCount
    }
}

/// Sidecar file persisted alongside each session's audio archive.
/// Stores the per-cluster centroid embeddings keyed by the in-
/// transcript label ("A", "B", "C"). When the user later renames
/// "Remote A" → "Alex" in SessionDetailView we load this file,
/// look up centroid for "A", and hand it to
/// `SpeakerProfileStore.upsert(name:embedding:)` so the new
/// profile encodes who Alex's voice sounds like.
///
/// File layout: `<session-dir>/speakers.json`.
struct SpeakerCentroidsFile: Codable, Sendable {
    let centroids: [String: [Float]]
}

/// Cosine similarity between two L2-normalized vectors. Since both
/// are unit-length, this reduces to a dot product. Range −1…+1;
/// FluidAudio's wespeaker_v2 produces embeddings where same-speaker
/// pairs typically score 0.7+ and different-speaker pairs sit below
/// 0.5.
///
/// Public so the matching logic + future ML test helpers can call
/// it; we don't depend on FluidAudio's internal `SpeakerOperations`
/// to keep this module independently testable.
nonisolated func speakerCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
    }
    // Vectors are already L2-normalized by the embedding model;
    // dot product == cosine. No division by magnitudes needed.
    return dot
}
