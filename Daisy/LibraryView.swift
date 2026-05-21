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
    /// Active client-tag filter. nil == "all clients", "" sentinel
    /// not used (the chip-row has an explicit "Untagged" entry which
    /// maps to `clientFilter = .some("")`). Persisted only across
    /// LibraryView's lifetime.
    @State private var clientFilter: String? = nil
    /// Pending delete confirmation. Carries the sessions about to
    /// be removed (1 for context-menu, N for multi-select).
    @State private var pendingDelete: [StoredSession] = []
    @State private var refreshRotation: Double = 0

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
        if n <= 1 { return "Delete this session?" }
        return "Delete \(n) sessions?"
    }

    private var deleteAlertMessage: String {
        let n = pendingDelete.count
        if n <= 1 {
            return "Audio, transcript, summary and screenshots will be removed from disk. This can't be undone."
        }
        return "Audio, transcript, summary and screenshots for all \(n) sessions will be removed from disk. This can't be undone."
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
            ForEach(folders.allFolders) { f in
                Button {
                    Task { await store.moveSession(session, to: f) }
                } label: {
                    if f.slug == session.folderSlug {
                        Label(f.name, systemImage: "checkmark")
                    } else {
                        Text(f.name)
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
                Label("Delete \(multi) selected", systemImage: "trash")
            } else {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Copy the on-disk transcript.md straight to the clipboard.
    /// Lightweight version of the detail-view copy action.
    private func copyTranscript(of session: StoredSession) {
        guard let url = session.transcriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            // Search + reload header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $query)
                    .textFieldStyle(.plain)
                Spacer(minLength: 0)
                Button {
                    Task { await store.refresh() }
                    withAnimation(.easeInOut(duration: 0.7)) {
                        refreshRotation += 360
                    }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(refreshRotation))
                }
                .buttonStyle(.plain)
                .help("Reload sessions from disk")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            folderChips
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            // Client chips appear only when at least one session has
            // a client tag — keeps the sidebar uncluttered for users
            // who don't tag sessions. Counts are live; "Untagged"
            // surfaces only when there's a mix.
            if !clientGroups.isEmpty {
                clientChips
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            // Manual selection model so we keep brand-coloured highlight
            // instead of the system gray that `List(selection:)` paints
            // on `.plain`. Shift / Cmd-click are handled here:
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
                                      ? Color.daisyAccent.opacity(0.18)
                                      : Color.clear)
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
                if store.sessions.isEmpty && !store.isLoading {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "tray",
                        description: Text("When you stop a recording, it'll appear here.")
                    )
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
            Label("\(selectedIDs.count) sessions selected", systemImage: "doc.on.doc")
        } description: {
            Text("Press ⌫ to delete the selection, or click a single row to read its transcript.")
        } actions: {
            Button(role: .destructive) {
                pendingDelete = store.sessions.filter { selectedIDs.contains($0.id) }
            } label: {
                Label("Delete \(selectedIDs.count) sessions…", systemImage: "trash")
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

    private var filteredSessions: [StoredSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = store.sessions
        if let f = folderFilter {
            pool = pool.filter { $0.folderSlug == f.slug }
        }
        if let c = clientFilter {
            pool = pool.filter { $0.client == c }
        }
        if !trimmed.isEmpty {
            pool = pool.filter { $0.matches(query: trimmed) }
        }
        return pool
    }

    /// All client tags present across sessions, sorted by count desc
    /// then alphabetically. "Untagged" (empty client) is split out as
    /// the last entry so it's visually demoted but still reachable.
    private var clientGroups: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for s in store.sessions {
            counts[s.client, default: 0] += 1
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

    /// Horizontally-scrollable client chips below the folder row.
    /// Same idiom as folderChips — "All" pseudo-chip resets the
    /// filter, individual chips toggle the filter on/off. "Untagged"
    /// is rendered last with a slightly secondary style so users
    /// understand it's the catch-all bucket.
    private var clientChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FolderChip(
                    label: "Any client",
                    count: store.sessions.count,
                    isActive: clientFilter == nil
                ) {
                    clientFilter = nil
                }
                ForEach(clientGroups, id: \.name) { group in
                    let label = group.name.isEmpty ? "Untagged" : group.name
                    FolderChip(
                        label: label,
                        count: group.count,
                        isActive: clientFilter == group.name
                    ) {
                        clientFilter = (clientFilter == group.name) ? nil : group.name
                    }
                }
            }
        }
    }

    /// Horizontally-scrollable folder chips above the session list.
    /// "All" + each folder; counts are live per-folder.
    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FolderChip(
                    label: "All",
                    count: store.sessions.count,
                    isActive: folderFilter == nil
                ) {
                    folderFilter = nil
                }
                ForEach(folders.allFolders) { f in
                    let count = store.sessions.filter { $0.folderSlug == f.slug }.count
                    FolderChip(
                        label: f.name,
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
            description: Text("Pick a session on the left to read its transcript and summary.")
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
                if !session.client.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(session.client)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.daisyAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.daisyAccent.opacity(0.10), in: Capsule())
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
            if session.hasSystemAudio {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Has system audio")
            }
            if session.hasScreenshots {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("\(session.screenshotURLs.count) screenshot\(session.screenshotURLs.count == 1 ? "" : "s")")
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
                        .foregroundStyle(isActive ? Color.white.opacity(0.75) : Color.daisyTextTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive ? Color.daisyAccent : Color.daisyBgSidebar.opacity(0.6))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? Color.clear : Color.daisyDivider, lineWidth: 0.5)
            )
            .foregroundStyle(isActive ? Color.white : Color.daisyTextPrimary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LibraryView()
}
