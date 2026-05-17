//
//  HistoryView.swift
//  Daisy
//
//  Browser for past recording sessions. Top-level NavigationSplitView:
//  left pane = list of sessions with search; right pane = full detail
//  (transcript + summary + screenshots + actions).
//

import SwiftUI
import AppKit

struct HistoryView: View {
    @Bindable var store = SessionStore.shared
    @Bindable var folders = FolderStore.shared
    @State private var query: String = ""
    @State private var selectedID: StoredSession.ID?
    /// Active folder filter. `nil` = show all folders.
    @State private var folderFilter: SessionFolder? = nil
    /// Pending delete confirmation — holds the session about to be
    /// removed. `nil` means no confirmation pending.
    @State private var pendingDelete: StoredSession? = nil
    @State private var refreshRotation: Double = 0

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
            // extends from the window's toolbar edge to the bottom,
            // no SwiftUI Divider-truncation in the middle of layout.
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 480)
        .task { await store.refresh() }
        .onAppear {
            if selectedID == nil {
                selectedID = store.sessions.first?.id
            }
        }
        .alert(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { session in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(session)
                    if selectedID == session.id { selectedID = nil }
                    pendingDelete = nil
                }
            }
        } message: { _ in
            Text("Audio, transcript, summary and screenshots will be removed from disk. This can't be undone.")
        }
    }

    // MARK: - Row context menu

    /// Same actions as SessionDetailView's ellipsis menu — Move /
    /// Send to Notion / Send to Claude / Reveal / Delete. Skips
    /// "Re-summarize" because that's a heavy async op better
    /// triggered from the detail view's banner-feedback flow.
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
            pendingDelete = session
        } label: {
            Label("Delete", systemImage: "trash")
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
                .padding(.bottom, 8)

            // Plain list — no `.sidebar` style, so no frosted glass.
            List(selection: $selectedID) {
                ForEach(filteredSessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .listRowSeparator(.hidden)
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
        if let id = selectedID, let session = store.sessions.first(where: { $0.id == id }) {
            SessionDetailView(session: session)
        } else {
            emptyDetail
        }
    }

    private var filteredSessions: [StoredSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = store.sessions
        if let f = folderFilter {
            pool = pool.filter { $0.folderSlug == f.slug }
        }
        if !trimmed.isEmpty {
            pool = pool.filter { $0.matches(query: trimmed) }
        }
        return pool
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
                    .foregroundStyle(.purple)
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
    HistoryView()
}
