//
//  SessionDetailView.swift
//  Daisy
//
//  Detail pane in the History window. Shows summary (if any), full
//  transcript text, screenshots gallery, and actions: re-summarize via
//  the current provider, export markdown, send to Notion / Claude,
//  reveal in Finder, or delete.
//

import SwiftUI
import AppKit

struct SessionDetailView: View {
    /// Initial snapshot — passed in by the caller (the History list).
    /// We don't render from this directly: instead we look the
    /// current value up in SessionStore by ID so the view reacts
    /// when the post-Stop detached task writes summary.json and
    /// SessionStore.reloadSession() replaces the row in-place.
    let initialSession: StoredSession

    /// Always-current session row. Falls back to the initial
    /// snapshot if the store hasn't loaded yet (cold launch into
    /// History view) or the session was deleted out from under us.
    private var session: StoredSession {
        SessionStore.shared.sessions
            .first(where: { $0.id == initialSession.id }) ?? initialSession
    }

    /// True while the post-Stop detached task is still running for
    /// this session — drives the skeleton placeholder in the
    /// summary slot until summary.json lands and SessionStore swaps
    /// in a fresh `StoredSession` with `summary != nil`.
    private var isSummaryGenerating: Bool {
        SessionStore.shared.sessionsGenerating.contains(initialSession.id)
    }

    @State private var isRunningAction = false
    @State private var actionStatus: ActionStatus = .idle
    @State private var confirmDelete = false
    /// Local draft for the tag field in the header. Mirrors
    /// `session.tag` and commits to disk on blur / Enter — same
    /// save-on-blur idiom the title editor below uses.
    @State private var tagDraft: String = ""
    @FocusState private var tagFieldFocused: Bool
    /// Notion-style autocomplete popover visibility. Bound to
    /// `tagFieldFocused` via .onChange so click-to-focus opens the
    /// suggestions, blur closes them. Held as its own @State because
    /// the popover's own dismiss-on-outside-click triggers a flip
    /// that wouldn't have a single binding source otherwise.
    @State private var showingTagSuggestions = false

    enum ActionStatus: Equatable {
        case idle
        case message(String)
        case error(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !actionStatusText.isEmpty { actionBanner }
                if let summary = session.summary {
                    summarySection(summary)
                } else if isSummaryGenerating {
                    summarySkeletonSection
                }
                if session.hasScreenshots { screenshotsSection }
                transcriptSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Action buttons live in the window toolbar's trailing zone,
        // at the same vertical level as the Daisy brand pill on the
        // leading side. macOS 26 Liquid Glass wraps each ToolbarItem
        // in its own pill automatically — visual grammar matches the
        // Daisy mark + title pill on the left.
        .toolbar { detailToolbar }
        .alert("Delete this session?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSession() }
            }
        } message: {
            Text("Audio, transcript, summary and screenshots will be removed from disk. This can't be undone.")
        }
    }

    // MARK: - Toolbar items (top-right corner of window)

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // macOS 26: ToolbarItemGroup renders the contained items inside
        // ONE shared Liquid Glass capsule. Symmetry on the leading and
        // trailing edges comes from (a) uniform horizontal padding per
        // icon in `toolbarIcon(_:)` and (b) `.fixedSize()` on the
        // ellipsis Menu to collapse the hidden chevron's phantom width.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                attemptReSummarize()
            } label: {
                toolbarIcon("sparkles")
            }
            .buttonStyle(.borderless)
            .help("Re-summarize via current provider")

            Button {
                attemptCopyMarkdown()
            } label: {
                toolbarIcon("doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy markdown to clipboard")

            Menu {
                Menu {
                    ForEach(FolderStore.shared.allFolders) { f in
                        Button {
                            Task { await moveTo(folder: f) }
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
                    Task { await sendToNotion() }
                } label: {
                    Label("Send to Notion", systemImage: "doc.text")
                }
                Button {
                    sendToClaude()
                } label: {
                    Label("Send to Claude", systemImage: "sparkles")
                }
                mcpIntegrationsMenuItems
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                toolbarIcon("ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Padding INSIDE the Menu label is eaten by Menu's
            // own size measurement (the previous attempt put it
            // on `toolbarIcon` directly and didn't survive).
            // Applying it OUTSIDE the Menu, after `.fixedSize()`,
            // pushes the entire Menu view inward from its
            // ToolbarItemGroup slot — which is the gap we actually
            // see on screen. 16pt overshoots the phantom chevron
            // (~12pt) by a few points so the visible gap matches
            // the 12pt sparkles has on the leading side.
            .padding(.trailing, 16)
            // Menu in macOS 26 toolbar inherits `.tint` colour for
            // its label glyph — bypasses Image.foregroundStyle. Pin
            // the tint locally so the ellipsis matches the other
            // toolbar icons instead of going orange via inherited
            // accent.
            .tint(Color.daisyTextPrimary)
        }
    }

    // MARK: - Action attempts (with toast feedback)

    /// Wraps reSummarize with pre-condition checks. When click
    /// can't proceed (no transcript / no provider), shows a toast
    /// so the user sees explicit feedback instead of a dead-button
    /// no-op.
    private func attemptReSummarize() {
        if isRunningAction {
            ToastCenter.shared.show("Already running — wait a moment", style: .info)
            return
        }
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show("No transcript to summarize yet", style: .warning)
            return
        }
        Task { await reSummarize() }
    }

    private func attemptCopyMarkdown() {
        guard !session.transcriptText.isEmpty else {
            ToastCenter.shared.show("No transcript yet", style: .warning)
            return
        }
        copyMarkdown()
        let scope = session.summary == nil ? "Transcript" : "Summary + transcript"
        ToastCenter.shared.show("\(scope) copied to clipboard", style: .success)
    }

    /// Uniform toolbar icon. `Color.daisyTextPrimary` is an explicit
    /// black/cream-warm depending on appearance — bypasses macOS 26's
    /// Liquid Glass tint inheritance that was washing the icons into
    /// inconsistent grays. `.symbolRenderingMode(.monochrome)` kills
    /// SF Symbols' default multicolor on `sparkles`. Horizontal
    /// padding gives the auto-fitted Liquid Glass pill breathing
    /// room around the glyph instead of hugging the edge.
    /// User-configured MCP integrations — one menu item per enabled
    /// integration. Empty when the user hasn't set anything up;
    /// nothing renders in that case (no spacer Divider).
    @ViewBuilder
    private var mcpIntegrationsMenuItems: some View {
        let store = MCPIntegrationStore.shared
        let enabled = store.enabledIntegrations
        if !enabled.isEmpty {
            Divider()
            ForEach(enabled) { integration in
                Button {
                    Task { await MCPDispatcher.send(integration, for: session) }
                } label: {
                    Label("Send to \(integration.name)", systemImage: "paperplane")
                }
            }
        }
    }

    /// One toolbar glyph. Uniform 6pt horizontal padding on every
    /// icon, full stop — the shared Liquid Glass capsule supplies its
    /// own inner inset on top of this, so each icon ends up with the
    /// same gap to the pill edge whether it's leading, middle, or
    /// trailing. Earlier `outerEdge` asymmetric padding only existed
    /// to compensate for the `Menu` chevron's phantom reservation;
    /// that's now handled at the call-site via `.fixedSize()`.
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.daisyTextPrimary)
            .font(.body.weight(.medium))
            // 12pt mirrors the brand pill in `MainView.swift:118`
            // (its comment: "bumped from 6 → 12 so the mark +
            // wordmark have room from the pill's left and right
            // edges instead of hugging them"). 6pt was producing
            // the exact same "icons hug the capsule edge" symptom
            // the brand pill fix was originally written to solve.
            .padding(.horizontal, 12)
    }

    // MARK: - Header (title + metadata; actions live in toolbar)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(formattedDate)
                Text("·")
                Text(formattedDuration)
                // Header used to surface two more chips here:
                //   • transcription locale ("AUTO" / "EN" / "RU"),
                //     already controlled in Settings → Transcription
                //     and doesn't change anything the user sees in
                //     the transcript itself;
                //   • a `speaker.wave.2` icon flagging that system
                //     audio was captured — read as cryptic visual
                //     debt, since the user already knows they
                //     recorded a meeting (the title literally says
                //     "Meeting 2026-…").
                // Removed in 1.0.6.4 — header now stays date · duration
                // · tag, which is what users actually scan for.
                Spacer()
                tagField
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { tagDraft = session.tag }
        .onChange(of: session.id) { _, _ in tagDraft = session.tag }
        .onChange(of: session.tag) { _, newValue in
            // External edit (e.g., from another window or a future
            // bulk tagging path) — reflect in the field unless the
            // user is actively editing it.
            if !tagFieldFocused { tagDraft = newValue }
        }
    }

    /// Inline tag editor in the header row. Free-text TextField
    /// for ad-hoc tags PLUS a dropdown chevron Menu that lists
    /// every tag already in use across the store so the user can
    /// pick instead of re-typing (e.g., one click selects
    /// "Mediacube" if it's been used before, instead of risking
    /// "Mediacube" / "mediacube" / "Mediacube " all becoming
    /// three different buckets).
    ///
    /// Notion-style autocomplete: focus on the TextField opens a
    /// popover below it listing every existing tag, filtered by
    /// what the user is currently typing. Click a row → tag is
    /// applied. Enter on a brand-new value → tag is created. No
    /// chevron — the popover IS the affordance.
    @ViewBuilder
    private var tagField: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextField("Add tag…", text: $tagDraft)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($tagFieldFocused)
                .frame(maxWidth: 140)
                .onSubmit {
                    commitTag()
                    tagFieldFocused = false
                }
                .onChange(of: tagFieldFocused) { _, isFocused in
                    if isFocused {
                        // Defer to next runloop so the popover
                        // anchors after the field's frame settled.
                        DispatchQueue.main.async {
                            showingTagSuggestions = true
                        }
                    } else {
                        commitTag()
                    }
                }
                .popover(
                    isPresented: $showingTagSuggestions,
                    attachmentAnchor: .point(.bottom),
                    arrowEdge: .top
                ) {
                    tagSuggestionsList
                        .frame(minWidth: 180, idealWidth: 200)
                        .padding(.vertical, 4)
                }
        }
    }

    /// Filtered list of existing tags shown in the popover beneath
    /// the field. Notion / Linear / Apple Reminders all use this
    /// shape — substring filter, click-to-pick, no per-row checkbox
    /// because tags are single-select.
    @ViewBuilder
    private var tagSuggestionsList: some View {
        let allTags = SessionStore.shared.distinctTagsByFrequency
        let query = tagDraft.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty
            ? allTags
            : allTags.filter { $0.lowercased().contains(query) }
        VStack(alignment: .leading, spacing: 0) {
            // "Create new" row — visible when the typed text doesn't
            // match an existing tag exactly. Lets the user commit a
            // brand-new value via mouse instead of Enter.
            if !query.isEmpty,
               !allTags.contains(where: { $0.lowercased() == query }) {
                tagSuggestionButton(
                    label: "Create \"\(tagDraft.trimmingCharacters(in: .whitespaces))\"",
                    systemImage: "plus.circle"
                ) {
                    commitTag()
                    showingTagSuggestions = false
                    tagFieldFocused = false
                }
                Divider()
            }

            // "Remove tag" row — only when this session is tagged,
            // so it can be cleared without typing.
            if !session.tag.isEmpty {
                tagSuggestionButton(
                    label: "Remove tag",
                    systemImage: "xmark.circle"
                ) {
                    tagDraft = ""
                    commitTag()
                    showingTagSuggestions = false
                    tagFieldFocused = false
                }
                Divider()
            }

            if filtered.isEmpty && query.isEmpty {
                Text("No tags yet — type to create one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(filtered, id: \.self) { name in
                    tagSuggestionButton(
                        label: name,
                        systemImage: session.tag == name ? "checkmark" : nil
                    ) {
                        tagDraft = name
                        commitTag()
                        showingTagSuggestions = false
                        tagFieldFocused = false
                    }
                }
            }
        }
    }

    /// One row in the suggestions popover — themed to match the
    /// surrounding chrome (plain button, hover-only highlight via
    /// `.borderless`). `systemImage` nil means no leading glyph.
    @ViewBuilder
    private func tagSuggestionButton(
        label: String,
        systemImage: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Text(label)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.daisyTextPrimary)
    }

    private func commitTag() {
        let trimmed = tagDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != session.tag else { return }
        Task { await SessionStore.shared.setTag(trimmed, for: session) }
    }


    // MARK: - Summary

    /// Placeholder shown above the transcript while the post-Stop
    /// detached summarize task is still running. Replaced in-place
    /// by `summarySection(...)` once `summary.json` lands and
    /// `SessionStore.reloadSession(id:)` flips the row to carry a
    /// non-nil `MeetingSummary`. Three rows mirror the real
    /// document layout (Meeting / Next actions / Follow-up) so the
    /// transition reads as "content arriving" rather than "layout
    /// shift".
    @ViewBuilder
    private var summarySkeletonSection: some View {
        mdSection(title: "Meeting") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating summary… transcript is ready below.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        mdSection(title: "Next actions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "square")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.daisyDivider)
                            .frame(height: 12)
                            .frame(maxWidth: .infinity)
                            .opacity(0.6)
                    }
                }
            }
        }
    }

    // Summary sections rendered as a plain MD-style document — no
    // coloured AI card, no sparkles header, no border. The user reads
    // this like a normal write-up: H2 heading, body text, bullets.
    // Each section is independent so the gestalt is "one document"
    // rather than "a feature card".
    //
    // 1.0.2: switched to a Granola-style outline. `summary.sections`
    // carries 3-5 topical chunks with hierarchical bullets, rendered
    // here as indented bullet trees. `summary.summary` is a one-line
    // lede above them. Legacy summaries written before the schema
    // change have `sections == []`; we fall back to rendering
    // `summary` as a paragraph plus a "Next actions" block, which
    // matches the old layout exactly so previously-saved sessions
    // don't suddenly look broken.
    @ViewBuilder
    private func summarySection(_ summary: MeetingSummary) -> some View {
        if summary.sections.isEmpty {
            // Legacy summary (pre-1.0.2): paragraph + flat actions.
            legacySummarySection(summary)
        } else {
            // Granola-style outline.
            granolaStyleSummary(summary)
        }

        if !summary.clientFollowUp.isEmpty {
            mdSection(title: summaryLabels(for: summary).followUp) {
                // ZStack instead of HStack: HStack with a sibling Button
                // alongside the Text was eating mouse hit-events over
                // the text area on macOS 26 — tester couldn't select +
                // ⌘C the follow-up despite .textSelection(.enabled).
                // ZStack with the button anchored top-trailing leaves
                // the Text occupying the full content width with
                // unobstructed selection, while the copy affordance
                // sits in the corner where it's still discoverable.
                ZStack(alignment: .topTrailing) {
                    Text(summary.clientFollowUp)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Padding-right reserves the corner for the
                        // copy button so it doesn't sit on top of
                        // text on long-line wraps.
                        .padding(.trailing, 28)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.clientFollowUp, forType: .string)
                        ToastCenter.shared.show("Follow-up draft copied", style: .success)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy the draft message")
                }
            }
        }
    }

    /// Detect the summary's output language from its own content so
    /// our structural headers ("Meeting" / "Next actions" / "Follow-
    /// up") match. We sample `summary.summary + first 200 chars of
    /// first section bullet` rather than picking up from a frontmatter
    /// field because pre-1.0.2 sessions don't carry the language
    /// anywhere. LanguageDetector returns nil on too-short / low-
    /// confidence input → falls through to English defaults, which
    /// is the same behaviour as a legacy English session.
    private func summaryLabels(for summary: MeetingSummary) -> SummaryLabels {
        var sample = summary.summary
        if sample.count < 60, let firstBullet = summary.sections.first?.bullets.first?.text {
            sample += " " + firstBullet
        }
        return SummaryLabels.for(language: LanguageDetector.detect(sample))
    }

    /// Granola-style: 1-line lede + topical outline + standalone
    /// "Next actions" with owner-prefixed items. The outline section
    /// titles come straight from the model — they're already
    /// localised (RU summaries get RU titles like "Следующие шаги"
    /// without us mapping anything). The STRUCTURAL headers (Meeting
    /// / Next actions / Follow-up) we localise ourselves via
    /// `summaryLabels(for:)`.
    @ViewBuilder
    private func granolaStyleSummary(_ summary: MeetingSummary) -> some View {
        let labels = summaryLabels(for: summary)
        if !summary.summary.isEmpty {
            mdSection(title: labels.meeting) {
                Text(summary.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
            mdSection(title: section.title) {
                bulletTree(section.bullets, level: 0)
            }
        }
        if !summary.actionItems.isEmpty {
            mdSection(title: labels.nextActions) {
                actionItemList(summary.actionItems)
            }
        }
    }

    /// Legacy pre-1.0.2 layout — paragraph + flat actions.
    /// Preserved verbatim so sessions saved on an older build keep
    /// rendering correctly. Localised headers via content detection
    /// — old summaries don't carry a language field but the lede
    /// itself is in the user's language, so `LanguageDetector` on
    /// `summary.summary` is reliable enough.
    @ViewBuilder
    private func legacySummarySection(_ summary: MeetingSummary) -> some View {
        let labels = summaryLabels(for: summary)
        mdSection(title: labels.meeting) {
            Text(summary.summary)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !summary.actionItems.isEmpty {
            mdSection(title: labels.nextActions) {
                actionItemList(summary.actionItems)
            }
        }
    }

    /// Shared renderer for the flat actionItems block. Each row is
    /// the checkbox-square icon + text; the owner prefix (if any) is
    /// part of the text itself so no special styling is needed.
    @ViewBuilder
    private func actionItemList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "square")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                    Text(item)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Hierarchical bullet renderer. Up to 3 levels of nesting in
    /// practice (prompt caps depth, but the view handles arbitrary
    /// depth recursively). Top level uses a darker mid-dot, deeper
    /// levels use lighter tertiary dots so the eye reads the
    /// indentation as semantic depth rather than just spacing.
    ///
    /// Returns `AnyView` rather than `some View` because the function
    /// is recursive: Swift 6 / Xcode 26 refuses to infer an opaque
    /// return type that references itself. Type-erasing breaks the
    /// self-reference. Cost is negligible at the typical depth/breadth.
    private func bulletTree(_ bullets: [SummaryBullet], level: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•")
                                .font(.body.weight(level == 0 ? .semibold : .regular))
                                .foregroundStyle(level == 0 ? .secondary : .tertiary)
                            Text(bullet.text)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !bullet.children.isEmpty {
                            bulletTree(bullet.children, level: level + 1)
                                .padding(.leading, 22)
                        }
                    }
                }
            }
        )
    }

    /// Document-style section: H2-weight heading, hairline rule under
    /// it, body content. Used for Meeting / Next actions / Follow-up /
    /// Transcript so the whole detail view reads as a single MD doc.
    @ViewBuilder
    private func mdSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Rectangle()
                    .fill(Color.daisyDivider)
                    .frame(height: 0.5)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screenshots

    private var screenshotsSection: some View {
        mdSection(title: "Screenshots (\(session.screenshotURLs.count))") {
            screenshotStrip
        }
    }

    private var screenshotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.screenshotURLs, id: \.self) { url in
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(width: 160, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture(count: 2) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        mdSection(title: "Transcript") {
            VStack(alignment: .leading, spacing: 12) {
                speakerMappingSection

                if session.transcriptText.isEmpty {
                    Text("No transcript text on disk.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(mappedTranscriptText)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Show "Name speakers" card whenever the transcript has
    /// detected speakers ("Remote A", "Remote B", ...). Previously
    /// gated on `meetingAttendees.isEmpty` — that made the feature
    /// invisible for manual recordings (no calendar event). Now
    /// every diarized session can be renamed; calendar attendees,
    /// when present, become quick-pick suggestions next to the
    /// free-text field.
    @ViewBuilder
    private var speakerMappingSection: some View {
        if !detectedSpeakerIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(Color.daisyAccent)
                    Text("Name the speakers")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !session.speakerMap.isEmpty {
                        Button("Clear") {
                            Task { await SessionStore.shared.updateSpeakerMap([:], for: session) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.daisyTextSecondary)
                    }
                }
                Text("Replace the auto-generated labels with real names. Names propagate to the transcript, the summary's follow-up, and any sent destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(detectedSpeakerIDs, id: \.self) { speakerID in
                    SpeakerNameRow(
                        speakerID: speakerID,
                        currentName: session.speakerMap[speakerID] ?? "",
                        attendeeSuggestions: session.meetingAttendees,
                        onCommit: { name in
                            Task { await applyMapping(speakerID: speakerID, name: name) }
                        }
                    )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.daisyAccent.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.daisyAccent.opacity(0.18), lineWidth: 0.5)
            )
        }
    }

    /// Speaker IDs ("A", "B", "C") that appear in the transcript body.
    /// Extracted from `[Remote A]` / `[Remote B]` markers — same
    /// format `MarkdownExporter` writes via `TranscriptSegment.speakerLabel`.
    private var detectedSpeakerIDs: [String] {
        let pattern = #/\bRemote\s+([A-Z])\b/#
        var seen: Set<String> = []
        for match in session.transcriptText.matches(of: pattern) {
            seen.insert(String(match.1))
        }
        return seen.sorted()
    }

    /// Substitute "Remote A" → mapped name inline. The on-disk .md
    /// stays in canonical "Remote A" form so the mapping is fully
    /// re-pluggable (just edit `daisy_speaker_map:` in frontmatter).
    private var mappedTranscriptText: String {
        guard !session.speakerMap.isEmpty else { return session.transcriptText }
        var text = session.transcriptText
        for (speakerID, name) in session.speakerMap {
            text = text.replacingOccurrences(
                of: "Remote \(speakerID)",
                with: name
            )
        }
        return text
    }

    private func applyMapping(speakerID: String, name: String?) async {
        var updated = session.speakerMap
        if let name {
            updated[speakerID] = name
        } else {
            updated.removeValue(forKey: speakerID)
        }
        await SessionStore.shared.updateSpeakerMap(updated, for: session)

        // Voice fingerprint persistence — when the user assigns a
        // real name to a speaker, look up that speaker's centroid
        // embedding from the session's `speakers.json` sidecar and
        // either create a new SpeakerProfile or update an existing
        // one. Next time the same person joins a recording, Daisy
        // will auto-label them ("Alex" instead of "Remote A").
        //
        // Skipped on "unmap" (name == nil) — we don't delete
        // profiles on clear, only on the explicit "Forget" action
        // in Settings → Speakers.
        guard let name, !name.isEmpty else { return }
        guard let centroids = loadSpeakerCentroids() else { return }
        guard let embedding = centroids[speakerID], !embedding.isEmpty else { return }
        SpeakerProfileStore.shared.upsert(name: name, embedding: embedding)
    }

    /// Read `speakers.json` from the session's directory. Returns
    /// nil if the sidecar is missing (older sessions recorded before
    /// the voice-fingerprint flow landed) or unreadable. Caller
    /// degrades gracefully — manual rename still works, it just
    /// won't seed a new profile.
    private func loadSpeakerCentroids() -> [String: [Float]]? {
        let url = session.directoryURL.appendingPathComponent("speakers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let parsed = try? JSONDecoder().decode(SpeakerCentroidsFile.self, from: data) else {
            return nil
        }
        return parsed.centroids
    }

    // MARK: - Status banner

    @ViewBuilder
    private var actionBanner: some View {
        let isError: Bool = {
            if case .error = actionStatus { return true }
            return false
        }()
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.daisyError : Color.daisySuccess)
            Text(actionStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
            Button {
                actionStatus = .idle
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            (isError ? Color.daisyError : Color.daisySuccess).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var actionStatusText: String {
        switch actionStatus {
        case .idle: return ""
        case .message(let m), .error(let m): return m
        }
    }

    // MARK: - Actions

    private func moveTo(folder: SessionFolder) async {
        isRunningAction = true
        actionStatus = .message("Moving to \(folder.name)…")
        await SessionStore.shared.moveSession(session, to: folder)
        actionStatus = .message("Moved to \(folder.name)")
        isRunningAction = false
    }

    private func reSummarize() async {
        guard !session.transcriptText.isEmpty else { return }
        isRunningAction = true
        actionStatus = .message("Summarizing via \(Summarizer.shared.providerKind.shortName)…")

        // Use the canonical locale resolver — same code path as the
        // post-Stop auto-summary, so re-summarize can never produce a
        // different language than the original run on the same
        // transcript. The resolver puts content-driven detection
        // first, so a Russian transcript whose frontmatter is
        // "auto" still gets a Russian re-summary.
        let localeHint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage
        )

        let result = await Summarizer.shared.summarize(
            transcript: session.transcriptText,
            title: session.title,
            localeHint: localeHint
        )

        if let summary = result {
            await SessionStore.shared.updateSummary(summary, for: session)
            actionStatus = .message("Summary updated.")
        } else if let err = Summarizer.shared.lastError {
            actionStatus = .error(err)
        } else {
            actionStatus = .error("No summary returned.")
        }
        isRunningAction = false
    }

    private func copyMarkdown() {
        // Assemble from in-memory state (transcriptText + summary)
        // rather than reading transcriptURL off disk. The on-disk
        // file might lag the current view — e.g., summary just arrived
        // from the LLM and the asynchronous summary.json + transcript.md
        // rewrite hasn't completed yet. Re-rendering matches exactly
        // what the user is looking at on screen.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(assembledMarkdown(), forType: .string)
        actionStatus = .message("Markdown copied to clipboard.")
    }

    /// Build a full markdown document for clipboard / share: title
    /// + summary (if present) + Granola-style sections + next actions
    /// + follow-up + transcript body. Mirrors `MarkdownExporter` but
    /// works against `StoredSession` (which `MarkdownExporter` doesn't
    /// take — it consumes the live `RecordingSession`).
    private func assembledMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")

        if let s = session.summary {
            let labels = summaryLabels(for: s)
            if !s.summary.isEmpty {
                lines.append("## \(labels.meeting)")
                lines.append("")
                lines.append(s.summary)
                lines.append("")
            }
            for section in s.sections {
                lines.append("### \(section.title)")
                lines.append("")
                appendBullets(section.bullets, level: 0, into: &lines)
                lines.append("")
            }
            if !s.actionItems.isEmpty {
                lines.append("## \(labels.nextActions)")
                lines.append("")
                for item in s.actionItems {
                    lines.append("- [ ] \(item)")
                }
                lines.append("")
            }
            if !s.clientFollowUp.isEmpty {
                lines.append("## \(labels.followUp)")
                lines.append("")
                // The follow-up is already paragraph-formatted by the
                // model (2-4 paragraphs separated by blank lines).
                // Pasting it verbatim preserves that paragraphing.
                lines.append(s.clientFollowUp)
                lines.append("")
            }
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(session.transcriptText)

        return lines.joined(separator: "\n")
    }

    /// Recursive bullet writer for `assembledMarkdown`. Two-space
    /// indent per level, matching CommonMark / Obsidian / Notion.
    private func appendBullets(_ bullets: [SummaryBullet], level: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: level)
        for b in bullets {
            lines.append("\(indent)- \(b.text)")
            if !b.children.isEmpty {
                appendBullets(b.children, level: level + 1, into: &lines)
            }
        }
    }

    private func sendToNotion() async {
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show("No transcript to send", style: .warning)
            return
        }
        if !AppSettings.notionConfigured {
            ToastCenter.shared.show("Set Notion token in Settings first", style: .warning)
            return
        }
        isRunningAction = true
        ToastCenter.shared.show("Sending to Notion…", style: .info)
        let data = exportData()
        do {
            let url = try await NotionExporter.shared.createMeetingPage(data)
            ToastCenter.shared.show("Notion page created", style: .success)
            NSWorkspace.shared.open(url)
        } catch {
            ToastCenter.shared.show("Notion: \(error.localizedDescription)", style: .error)
        }
        isRunningAction = false
    }

    private func sendToClaude() {
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show("No transcript to send", style: .warning)
            return
        }
        let opened = ClaudeExporter.sendToClaude(data: exportData())
        if opened {
            ToastCenter.shared.show("Prompt copied — switch to Claude and ⌘V", style: .success)
        } else {
            ToastCenter.shared.show("Prompt copied — claude.ai opened", style: .success)
        }
    }

    private func deleteSession() async {
        await SessionStore.shared.delete(session)
        // SwiftUI will pop us back to the empty state when the session
        // disappears from the store.
    }

    /// Build a MeetingExportData snapshot from this stored session so we
    /// can reuse the existing Notion + Claude exporters.
    private func exportData() -> MeetingExportData {
        let chunks = Self.chunkTranscript(session.transcriptText)
        return MeetingExportData(
            title: session.title,
            summary: session.summary,
            transcriptChunks: chunks,
            durationSeconds: session.durationSec,
            locale: session.locale,
            startedAt: session.startedAt
        )
    }

    private static func chunkTranscript(_ text: String) -> [String] {
        let limit = 1500
        var chunks: [String] = []
        var current = ""
        for paragraph in text.split(separator: "\n\n", omittingEmptySubsequences: true) {
            let line = String(paragraph)
            if current.count + line.count + 2 > limit {
                if !current.isEmpty { chunks.append(current) }
                current = line
            } else {
                current = current.isEmpty ? line : "\(current)\n\n\(line)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Formatting

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

// MARK: - Speaker name row
//
// One row inside the "Name the speakers" card. Shows the
// auto-detected "Remote A / B / C" label as the row anchor,
// a free-text TextField for the human name, and an optional
// suggestions Menu when calendar attendees are present.
//
// Save-on-blur semantics: typing → local @State; commits to the
// store on `.onSubmit` (Return) and on focus loss. No explicit
// Save button keeps the UX inline + intent-driven.

private struct SpeakerNameRow: View {
    let speakerID: String
    let currentName: String
    let attendeeSuggestions: [String]
    let onCommit: (String?) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(speakerID: String, currentName: String, attendeeSuggestions: [String], onCommit: @escaping (String?) -> Void) {
        self.speakerID = speakerID
        self.currentName = currentName
        self.attendeeSuggestions = attendeeSuggestions
        self.onCommit = onCommit
        self._draft = State(initialValue: currentName)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Remote \(speakerID)")
                .font(.callout.weight(.medium))
                .frame(width: 96, alignment: .leading)
                .foregroundStyle(Color.daisyTextSecondary)
            TextField("Name…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    // Commit on blur so users who click away
                    // (rather than press Return) still persist.
                    if !isFocused { commit() }
                }
            // Suggestions menu — present only when the session has
            // calendar attendees. Quick-fill from the bound event,
            // still allows free-text in the field next to it.
            if !attendeeSuggestions.isEmpty {
                Menu {
                    ForEach(attendeeSuggestions, id: \.self) { name in
                        Button(name) {
                            draft = name
                            commit()
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick from event attendees")
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        // Empty input clears the mapping — same as pre-fix `Unmapped`
        // button. Caller distinguishes nil vs string.
        if trimmed.isEmpty {
            // Only call onCommit if there was previously a value
            // (avoids spamming writes on focus loss of an unset row).
            if !currentName.isEmpty {
                onCommit(nil)
            }
        } else if trimmed != currentName {
            onCommit(trimmed)
        }
    }
}
