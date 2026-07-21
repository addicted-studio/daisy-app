//
//  LibraryView.swift
//  Daisy
//
//  Browser for past recording sessions. Top-level NavigationSplitView:
//  left pane = list of sessions with search; right pane = full detail
//  (transcript + summary + screenshots + actions).
//
//  Sidebar entry is called "Library" — `HistoryView` was the original
//  name when it framed the section as a chronological log; renamed
//  2026-05-19 alongside the shift to a curated-collection mental model
//  (Granola / Cleft / Apple Books / Music pattern).
//

import SwiftUI
import AppKit

struct LibraryView: View {
    /// Which slice of the corpus this instance shows. `.all` is the
    /// Library proper (everything EXCEPT the Notes folder — voice notes
    /// live in their own top-level Notes tab now). `.notes` is that tab:
    /// only the Notes folder, folder chips hidden (the folder is fixed).
    /// Same view, same model, same detail pane — just a scoped pool.
    enum Scope: Equatable { case all, notes }
    let scope: Scope

    init(scope: Scope = .all) { self.scope = scope }

    @Bindable var store = SessionStore.shared
    @Bindable var folders = FolderStore.shared
    @State private var query: String = ""
    /// Selected session IDs. Multi-select via Shift-click (range)
    /// and Cmd-click (toggle). When exactly one is selected, the
    /// detail pane shows it. When several, the pane shows a "N
    /// selected" empty-state with a bulk-delete CTA.
    @State private var selectedIDs: Set<StoredSession.ID> = []
    /// Active folder filter. `nil` = show all folders.
    @State private var folderFilter: SessionFolder? = nil
    /// Active tag filter. `nil` == "all tags" (no filter). `.some("")`
    /// == "untagged" bucket only. `.some("Mediacube")` == that exact
    /// tag. Driven by the selector dropdown above the session list.
    @State private var tagFilter: String? = nil
    /// Pending delete confirmation. Carries the sessions about to
    /// be removed (1 for context-menu, N for multi-select).
    @State private var pendingDelete: [StoredSession] = []
    // refreshRotation removed in 1.0.6.1 along with the dormant
    // manual-reload button. Store auto-refreshes on .task / focus /
    // FSEvents.

    /// Single selected session, used as a derived view for the
    /// detail pane. `nil` when 0 or >1 selected.
    private var singleSelected: StoredSession? {
        guard selectedIDs.count == 1,
              let id = selectedIDs.first else { return nil }
        return store.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        // Plain HStack instead of NavigationSplitView — we don't need
        // SwiftUI's nested-split chrome (its sidebar style + merged
        // toolbar were causing visual jank when nested inside MainView).
        // A simple list + divider + detail gives full control over
        // sizing and removes the frosted-glass list backplate.
        HStack(spacing: 0) {
            sessionList
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            // Manual vertical divider drawn full-bleed so it visually
            // extends from the window's title-bar edge to the bottom.
            // `.ignoresSafeArea(.container, edges: .top)` on the
            // divider alone (not the whole HStack) extends just this
            // hairline up through the toolbar safe area, without
            // pulling the rest of the content under the toolbar.
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 480)
        .task { await store.refresh() }
        .onAppear {
            consumePendingSelection()
            if selectedIDs.isEmpty, let first = store.sessions.first?.id {
                selectedIDs = [first]
            }
        }
        // Deep-link arrival: HomeView (and similar) can request a
        // specific session via `AppNavigation.openInLibrary(_:)`.
        // We react to that request both on first appear (above) and
        // any subsequent arrivals while the view is already mounted.
        .onChange(of: AppNavigation.shared.pendingLibrarySelection) { _, _ in
            consumePendingSelection()
        }
        // Backspace / forward-Delete on the History view trigger the
        // bulk-delete confirmation. `.onDeleteCommand` only fires
        // when the responder chain has a focused view that opted in —
        // our rows use a manual gesture model, so the List never
        // receives focus and `.onDeleteCommand` never fires. Hidden
        // buttons with `.keyboardShortcut` work without focus.
        //
        // `.disabled(...)` guards both buttons so neither hijacks
        // Backspace while the user is typing in the search field
        // (TextField captures the key first anyway, but this is
        // belt-and-braces).
        .background {
            Group {
                Button("Delete selected sessions") {
                    requestBulkDelete()
                }
                .keyboardShortcut(.delete, modifiers: [])

                Button("Forward-delete selected sessions") {
                    requestBulkDelete()
                }
                .keyboardShortcut(.deleteForward, modifiers: [])

                // ⌘+Delete — macOS convention (Finder, Notes, Mail
                // all bind "move to trash" to ⌘+⌫). Mirrors the bare
                // Backspace path; same alert, same destruction.
                Button("Delete selected (⌘⌫)") {
                    requestBulkDelete()
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .hidden()
            .disabled(selectedIDs.isEmpty)
        }
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { !pendingDelete.isEmpty },
                set: { if !$0 { pendingDelete = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = [] }
            Button("Delete", role: .destructive) {
                let victims = pendingDelete
                Task {
                    if victims.count == 1, let only = victims.first {
                        await store.delete(only)
                    } else {
                        await store.deleteMany(victims)
                    }
                    selectedIDs.subtract(victims.map(\.id))
                    pendingDelete = []
                }
            }
            // Enter confirms — by default macOS binds Return to the
            // .cancel role and leaves destructive buttons un-defaulted
            // (anti-fat-finger). User explicitly asked for keyboard-
            // first delete flow, so we promote Delete to .defaultAction.
            // Esc still maps to Cancel via the .cancel role.
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(deleteAlertMessage)
        }
    }

    /// Pull the pending session id from `AppNavigation`, focus the
    /// row, and clear the request so it doesn't fire again. Called
    /// on appear AND on changes — the latter handles deep-links
    /// while the History tab is already the active one.
    private func consumePendingSelection() {
        guard let pending = AppNavigation.shared.pendingLibrarySelection else { return }
        if store.sessions.contains(where: { $0.id == pending }) {
            selectedIDs = [pending]
        }
        AppNavigation.shared.pendingLibrarySelection = nil
    }

    /// Resolve the current selection into a delete-confirmation
    /// request. No-op if nothing's selected. Shared by the Backspace
    /// shortcut and (potentially) any future bulk-delete button.
    private func requestBulkDelete() {
        let toDelete = store.sessions.filter { selectedIDs.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        pendingDelete = toDelete
    }

    private var deleteAlertTitle: String {
        let n = pendingDelete.count
        if n <= 1 { return String(localized: "Delete this recording?") }
        return String(localized: "Delete \(n) recordings?")
    }

    private var deleteAlertMessage: String {
        let n = pendingDelete.count
        if n <= 1 {
            return String(localized: "Audio, transcript, summary and screenshots will be removed from disk. This can't be undone.")
        }
        return String(localized: "Audio, transcript, summary and screenshots for all \(n) sessions will be removed from disk. This can't be undone.")
    }

    // MARK: - Row context menu

    /// Same actions as SessionDetailView's ellipsis menu — Move /
    /// Send to Notion / Send to Claude / Reveal / Delete. Skips
    /// "Re-summarize" because that's a heavy async op better
    /// triggered from the detail view's banner-feedback flow.
    ///
    /// If the user right-clicked a row that's part of a multi-
    /// selection, Delete applies to the whole selection (matches
    /// Finder behaviour). Otherwise it acts on just this row.
    @ViewBuilder
    private func sessionContextMenu(for session: StoredSession) -> some View {
        Menu {
            ForEach(moveTargets, id: \.folder.slug) { row in
                let f = row.folder
                Button {
                    Task { await store.moveSession(session, to: f) }
                } label: {
                    let label = row.isChild ? "    \(f.name)" : f.name
                    if f.slug == session.folderSlug {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label("Move to folder…", systemImage: "folder")
        }
        Divider()
        Button {
            copyTranscript(of: session)
        } label: {
            Label("Copy transcript", systemImage: "doc.on.doc")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            let multi = store.sessions.filter { selectedIDs.contains($0.id) }
            if multi.count > 1, multi.contains(where: { $0.id == session.id }) {
                pendingDelete = multi
            } else {
                pendingDelete = [session]
            }
        } label: {
            let multi = selectedIDs.count
            if multi > 1 && selectedIDs.contains(session.id) {
                Label(String(localized: "Delete \(multi) selected"), systemImage: "trash")
            } else {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Copy the on-disk transcript.md to the clipboard. Lightweight
    /// version of the detail-view copy action — same two-flavor write
    /// (MarkdownClipboard.swift): semantic HTML for rich paste targets
    /// (Slack / Notion / Gmail / Apple Notes), raw markdown for plain
    /// ones (Obsidian / Claude / editors). The leading YAML frontmatter
    /// is stripped — it belongs only in the .md file on disk and the
    /// detail view's explicit "Copy for Obsidian", never in a copy the
    /// user drops into a chat or note (was: raw file, frontmatter and
    /// all, written as plain text only — literal `##`/`**` everywhere
    /// but Obsidian).
    private func copyTranscript(of session: StoredSession) {
        guard let url = session.transcriptURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        RichClipboard.copy(markdown: Self.strippingFrontmatter(raw))
    }

    /// Drop a leading `---`-fenced YAML block, returning just the body.
    /// Inverse of `SessionDetailView.onDiskFrontmatter`; returns the
    /// input unchanged when there is no well-formed frontmatter.
    private static func strippingFrontmatter(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return raw }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(i + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            // Search + tag-filter header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $query)
                    .textFieldStyle(.plain)
                Spacer(minLength: 0)
                // Tag selector lives here in 1.0.6 — Egor moved it
                // up from a separate row below folder chips so it
                // shares the capsule region with search. Only
                // renders when there's at least one real tag in
                // use; keeps the bar uncluttered for users who
                // haven't tagged anything yet.
                if tagGroups.contains(where: { !$0.name.isEmpty }) {
                    tagSelector
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            // Bumped from 8 → 14 in 1.0.6 because the folder chip row
            // visually touched the search bar — the capsule of the
            // "All" chip sat right under the text-field's baseline.
            .padding(.bottom, 14)

            // Folder chips only in the full Library — the Notes tab is
            // itself a fixed-folder view, so a folder picker there is
            // meaningless.
            if scope == .all {
                folderChips
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            // Manual selection model keeps the custom neutral highlight
            // while preserving Finder-style Shift / Cmd-click behaviour:
            //   • bare click  → select only this row
            //   • Cmd-click   → toggle this row in the selection
            //   • Shift-click → extend selection from anchor to this row
            // (matches Finder / Mail conventions). Anchor is the last
            // row that was selected by a bare click.
            List {
                ForEach(filteredSessions) { session in
                    SessionRow(session: session)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedIDs.contains(session.id)
                                      ? Color.daisySelectionBackground
                                      : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    selectedIDs.contains(session.id)
                                        ? Color.daisySelectionBorder
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                        .gesture(rowTapGesture(for: session))
                        .contextMenu {
                            sessionContextMenu(for: session)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if scopedSessions.isEmpty && !store.isLoading {
                    if scope == .notes {
                        ContentUnavailableView(
                            "No notes yet",
                            systemImage: "note.text",
                            description: Text("Hold your dictation key, or use the voice-note shortcut, to capture a quick note. It'll land here.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No recordings yet",
                            systemImage: "tray",
                            description: Text("When you stop a recording, it'll appear here.")
                        )
                    }
                } else if filteredSessions.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if filteredSessions.isEmpty, let f = folderFilter {
                    ContentUnavailableView(
                        "No recordings in \(f.name)",
                        systemImage: "folder",
                        description: Text("Move a recording into this folder from its detail view.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let session = singleSelected {
            SessionDetailView(initialSession: session)
        } else if selectedIDs.count > 1 {
            multiSelectDetail
        } else {
            emptyDetail
        }
    }

    private var multiSelectDetail: some View {
        ContentUnavailableView {
            Label(String(localized: "\(selectedIDs.count) recordings selected"), systemImage: "doc.on.doc")
        } description: {
            Text("Press ⌫ to delete the selection, or click a single row to read its transcript.")
        } actions: {
            Button(role: .destructive) {
                pendingDelete = store.sessions.filter { selectedIDs.contains($0.id) }
            } label: {
                Label(String(localized: "Delete \(selectedIDs.count) sessions…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyError)
        }
    }

    /// SwiftUI gesture that runs the multi-select / single-select
    /// logic. Read the current event's modifier flags from NSEvent
    /// (SwiftUI's `.onTapGesture` doesn't carry modifiers).
    private func rowTapGesture(for session: StoredSession) -> some Gesture {
        TapGesture().onEnded {
            let mods = NSEvent.modifierFlags
            if mods.contains(.shift), let anchor = selectedIDs.first ?? store.sessions.first?.id {
                // Range select between anchor and this row.
                let ids = filteredSessions.map(\.id)
                if let a = ids.firstIndex(of: anchor),
                   let b = ids.firstIndex(of: session.id) {
                    let range = a <= b ? a...b : b...a
                    selectedIDs = Set(ids[range])
                    return
                }
                selectedIDs = [session.id]
            } else if mods.contains(.command) {
                // Toggle this row in the selection.
                if selectedIDs.contains(session.id) {
                    selectedIDs.remove(session.id)
                } else {
                    selectedIDs.insert(session.id)
                }
            } else {
                // Bare click — single select.
                selectedIDs = [session.id]
            }
        }
    }

    /// Corpus narrowed to this tab's scope, BEFORE the user's own
    /// folder/tag/search filters. Every derived surface (list, folder
    /// chips, tag groups, counts) reads from this so scope stays
    /// consistent across all of them.
    private var scopedSessions: [StoredSession] {
        let notesSlug = SessionFolder.notes.slug
        switch scope {
        case .all:   return store.sessions.filter { $0.folderSlug != notesSlug }
        case .notes: return store.sessions.filter { $0.folderSlug == notesSlug }
        }
    }

    private var filteredSessions: [StoredSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = scopedSessions
        if let f = folderFilter {
            // Selecting a project parent aggregates its child folders'
            // records too; a leaf folder scopes to just itself.
            let scope = folders.slugScope(for: f)
            pool = pool.filter { scope.contains($0.folderSlug) }
        }
        if let t = tagFilter {
            pool = pool.filter { $0.tag == t }
        }
        if !trimmed.isEmpty {
            // Index-prefiltered substring search — same results as
            // filtering on `matches(query:)` directly, but without
            // re-scanning every transcript on each keystroke.
            pool = store.sessionsMatching(trimmed, in: pool)
        }
        return pool
    }

    /// All tags present across sessions, sorted by count desc then
    /// alphabetically. "Untagged" (empty tag) is appended last so
    /// it's visually demoted but still reachable from the selector.
    /// Powers both the sidebar selector and the autocomplete inside
    /// SessionDetail's tag editor.
    var tagGroups: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for s in scopedSessions {
            counts[s.tag, default: 0] += 1
        }
        let tagged = counts
            .filter { !$0.key.isEmpty }
            .map { (name: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.lowercased() < $1.name.lowercased()
            }
        let untaggedCount = counts[""] ?? 0
        if untaggedCount > 0 {
            return tagged + [(name: "", count: untaggedCount)]
        }
        return tagged
    }

    /// Single-selection dropdown listing every tag in use, with
    /// "All tags" reset at the top and "Untagged" demoted to the
    /// bottom. Lives inside the search-row header in 1.0.6 — compact
    /// trigger (tag icon + label + chevron). An active filter gains
    /// primary ink without borrowing the recording/brand signal colour.
    private var tagSelector: some View {
        Menu {
            Button {
                tagFilter = nil
            } label: {
                if tagFilter == nil {
                    Label("All tags", systemImage: "checkmark")
                } else {
                    Text("All tags")
                }
            }
            Divider()
            ForEach(tagGroups, id: \.name) { group in
                let displayName = group.name.isEmpty ? String(localized: "Untagged") : group.name
                Button {
                    tagFilter = (tagFilter == group.name) ? nil : group.name
                } label: {
                    if tagFilter == group.name {
                        Label("\(displayName) · \(group.count)", systemImage: "checkmark")
                    } else {
                        Text("\(displayName) · \(group.count)")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "tag")
                    .font(.caption)
                    .foregroundStyle(tagFilter == nil ? Color.daisyTextSecondary : Color.daisyTextPrimary)
                Text(tagSelectorLabel)
                    .font(.caption)
                    .foregroundStyle(tagFilter == nil ? Color.daisyTextSecondary : Color.daisyTextPrimary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by tag")
    }

    private var tagSelectorLabel: String {
        switch tagFilter {
        case nil:        return String(localized: "Tags")
        case .some(""):  return String(localized: "Untagged")
        case .some(let t): return t
        }
    }

    /// Move-to targets in hierarchy order: every folder (incl. Notes and
    /// Inbox), children indented under their parent project.
    private var moveTargets: [(folder: SessionFolder, isChild: Bool)] {
        var rows: [(folder: SessionFolder, isChild: Bool)] = []
        for root in folders.rootFolders {
            rows.append((root, false))
            for child in folders.children(of: root.slug) {
                rows.append((child, true))
            }
        }
        return rows
    }

    /// Folders flattened for the chip row in hierarchy order: each root
    /// followed by its children. Notes excluded (own tab).
    private var chipRows: [(folder: SessionFolder, isChild: Bool)] {
        var rows: [(folder: SessionFolder, isChild: Bool)] = []
        for root in folders.rootFolders where root.slug != SessionFolder.notes.slug {
            rows.append((root, false))
            for child in folders.children(of: root.slug) {
                rows.append((child, true))
            }
        }
        return rows
    }

    /// Horizontally-scrollable folder chips above the session list.
    /// "All" + each folder; counts are live per-folder.
    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FolderChip(
                    label: String(localized: "All"),
                    count: scopedSessions.count,
                    isActive: folderFilter == nil
                ) {
                    folderFilter = nil
                }
                // Project hierarchy, flattened for the horizontal chip
                // row: each root, immediately followed by its child
                // folders (prefixed "↳"). A parent's count aggregates its
                // children (matches what selecting it shows); a leaf
                // counts only itself. Notes has its own top-level tab, so
                // it's dropped from the Library chips.
                ForEach(chipRows, id: \.folder.slug) { row in
                    let f = row.folder
                    let scope = row.isChild ? [f.slug] : folders.slugScope(for: f)
                    let count = scopedSessions.filter { scope.contains($0.folderSlug) }.count
                    FolderChip(
                        label: row.isChild ? "↳ \(f.name)" : f.name,
                        count: count,
                        isActive: folderFilter?.slug == f.slug
                    ) {
                        folderFilter = (folderFilter?.slug == f.slug) ? nil : f
                    }
                }
            }
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView(
            "Select a recording",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Pick a recording on the left to read its transcript and summary.")
        )
    }
}

// MARK: - Sidebar row

private struct SessionRow: View {
    let session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                badges
            }
            HStack(spacing: 6) {
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.tag.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(session.tag)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.daisyTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.daisySelectionBackground, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.daisySelectionBorder, lineWidth: 0.5)
                        )
                }
                Spacer()
            }
            if !session.transcriptPreview.isEmpty {
                Text(session.transcriptPreview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            // `speaker.wave.2` (hasSystemAudio) removed in 1.0.6.4 —
            // it was repeating what the session title already says
            // ("Meeting …" implies system audio was on). Removed
            // here for parity with SessionDetailView header where it
            // was dropped for the same reason.
            if session.hasScreenshots {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "\(session.screenshotURLs.count) screenshots"))
            }
            if session.hasSummary {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(Color.daisyAccent)
                    .help("Has AI summary")
            }
        }
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: session.startedAt)
    }

    private var formattedDuration: String {
        let total = max(0, session.durationSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Folder chip

private struct FolderChip: View {
    let label: String
    let count: Int
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isActive ? Color.daisyTextSecondary : Color.daisyTextTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive ? Color.daisySelectionBackground : Color.daisyBgElevated)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Color.daisySelectionBorder : Color.daisyDivider,
                        lineWidth: isActive ? 1 : 0.5
                    )
            )
            .foregroundStyle(Color.daisyTextPrimary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LibraryView()
}
