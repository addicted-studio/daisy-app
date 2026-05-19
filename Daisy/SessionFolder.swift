//
//  SessionFolder.swift
//  Daisy
//
//  Project folder taxonomy for recordings. Used in two places:
//   • RecordingSession holds the active folder, which becomes the
//     `daisy_folder:` value in the transcript markdown frontmatter
//     when the session is saved.
//   • LibraryView filters the sidebar session list by selected folder.
//
//  The taxonomy is open — built-in defaults (Inbox / Private / Work
//  / Calls) plus user-defined folders persisted in UserDefaults.
//  Names are matched case-insensitively when reading back from the
//  filesystem so a transcript saved as "work" still appears under
//  "Work" in the UI.
//

import Foundation
import Observation

/// A folder is just a string identifier — `name` is the canonical
/// case-preserved label, `slug` is the lowercased token used for
/// frontmatter persistence and equality. Using a struct instead of an
/// enum lets users add custom folders without us shipping a code
/// change.
struct SessionFolder: Identifiable, Hashable, Codable, Sendable {
    let name: String
    var id: String { slug }
    var slug: String { name.lowercased() }
}

extension SessionFolder {
    static let inbox   = SessionFolder(name: "Inbox")
    static let notes   = SessionFolder(name: "Notes")
    static let private_ = SessionFolder(name: "Private")
    static let work    = SessionFolder(name: "Work")
    static let calls   = SessionFolder(name: "Calls")

    /// Built-in folders, in display order. Always present.
    /// `Notes` was added 2026-05-18 — Daisy works just as well as a
    /// voice-memo recorder, and a built-in folder makes the use case
    /// surface in the History sidebar without any UX changes
    /// elsewhere. Solo recordings can be moved there via the kebab's
    /// "Move to folder…" action; from there they filter alongside
    /// regular meetings.
    static let builtIn: [SessionFolder] = [.inbox, .notes, .private_, .work, .calls]
}

// MARK: - Store

@Observable
@MainActor
final class FolderStore {
    static let shared = FolderStore()

    /// All folders the user has — built-in + custom. Custom folders
    /// appear after built-in.
    var allFolders: [SessionFolder] {
        SessionFolder.builtIn + customFolders
    }

    private(set) var customFolders: [SessionFolder] {
        didSet {
            persist()
        }
    }

    private static let storageKey = "daisy.customFolders"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SessionFolder].self, from: data) {
            self.customFolders = decoded
        } else {
            self.customFolders = []
        }
    }

    /// Add a new custom folder. No-op if a folder with the same slug
    /// already exists (built-in or custom). Returns the canonical
    /// folder reference.
    @discardableResult
    func addFolder(named raw: String) -> SessionFolder {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .inbox }
        let candidate = SessionFolder(name: trimmed)
        if let existing = allFolders.first(where: { $0.slug == candidate.slug }) {
            return existing
        }
        customFolders.append(candidate)
        return candidate
    }

    /// Remove a custom folder. Built-in folders can't be removed.
    func removeFolder(_ folder: SessionFolder) {
        guard !SessionFolder.builtIn.contains(folder) else { return }
        customFolders.removeAll { $0.slug == folder.slug }
    }

    /// Look up a folder by its frontmatter slug. Falls back to Inbox
    /// for unknown / missing slugs so old transcripts (pre-folders)
    /// still surface.
    func folder(slug: String?) -> SessionFolder {
        guard let slug, !slug.isEmpty else { return .inbox }
        if let match = allFolders.first(where: { $0.slug == slug.lowercased() }) {
            return match
        }
        // Unknown slug — keep the user's data by auto-creating a
        // matching folder. They typed it in once, we shouldn't lose
        // it.
        return addFolder(named: slug)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customFolders) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
