//
//  SettingsView.swift
//  Daisy
//
//  Four-tab settings window:
//   • Capture        — mic toggle (always on), system audio, screenshots
//   • Transcription  — Whisper model picker (size vs accuracy)
//   • Summary        — provider picker (Apple / Anthropic / OpenAI)
//                      + API keys + model per provider + auto-summarize toggle
//   • Notion         — token + parent ID
//

import EventKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var whisper = WhisperEngine.shared
    @Bindable var summarizer = Summarizer.shared
    // Calendar source state — needed by the General-tab Calendar
    // section (autoStart / autoStop / menu-bar next-meeting toggles).
    // Bound to the SAME observable the Permissions tab reads
    // (SystemPermissions.shared) so the two surfaces can't disagree
    // about "is calendar granted". SystemPermissions auto-refreshes
    // on `NSApplication.didBecomeActiveNotification`, so toggling the
    // grant in System Settings → Privacy & Security and tabbing back
    // to Daisy updates this view without manual refresh.
    @Bindable private var systemPermissions = SystemPermissions.shared
    @Bindable private var googleAccount = GoogleAccountStore.shared

    @State private var summaryTestResult: TestResult = .idle
    @State private var notionTestResult: TestResult = .idle
    /// Drives the modal sheet that holds the secret / parent-id /
    /// parent-type / Test connection fields. Pre-1.0.5.4 this lived
    /// inside a DisclosureGroup inline in the Storage section, which
    /// pushed the rest of the form down and left a visible empty
    /// row when collapsed. Sheet keeps the row compact.
    @State private var showingNotionSettings = false

    enum TestResult: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    /// Last summary produced by Test summary — drives the preview
    /// block that shows up after a successful run. Cleared on each
    /// new test so the preview always matches the latest probe.
    @State private var summaryTestPreview: MeetingSummary?

    /// Bumped after the user picks / clears the sessions folder so
    /// the displayed path refreshes. `SessionsFolder` is plain
    /// UserDefaults under the hood — not @Observable — so SwiftUI
    /// needs a state nudge to re-read the path.
    @State private var storageRefreshTick: Int = 0
    /// Live list of input devices for the Capture-tab mic picker.
    /// Re-read on generalTab .task and on the Refresh button so the
    /// picker reflects current plugged-in hardware without us having
    /// to subscribe to CoreAudio hot-plug notifications (added in
    /// post-launch hardening).
    @State private var micDevices: [AudioInputDevice] = []
    /// On-disk Whisper cache stats — populated by an off-thread
    /// scan in `transcriptionTab.task`. `cacheRefreshTick` is the
    /// nudge the task watches; we bump it after Remove unused so
    /// the UI re-reads the freshly-shrunk cache.
    @State private var cachedModelsCount: Int = 0
    @State private var cachedModelsBytes: Int64 = 0
    @State private var cacheRefreshTick: Int = 0

    /// On-disk size of all known `.caf` audio archives across
    /// every session. Drives the "Clear audio cache" row caption
    /// in Storage. Populated by an off-thread scan, bumped by
    /// `audioCacheRefreshTick` after the manual purge so the
    /// freshly-zeroed size shows up immediately.
    @State private var audioCacheFiles: Int = 0
    @State private var audioCacheBytes: Int64 = 0
    @State private var audioCacheRefreshTick: Int = 0
    /// Drives the destructive-confirm alert before `runNow()`.
    @State private var showingClearAudioConfirm = false
    /// Set while the sweep is running so the button shows
    /// progress + can't be double-clicked.
    @State private var clearingAudioCache = false

    /// Cached `ByteCountFormatter` for the cache-size row. Building
    /// one per body recompute is wasteful; this one stays alive for
    /// the view lifetime.
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    /// Active sub-tab inside Settings. Bound to TabView's selection
    /// so external surfaces (FirstRunView, Home CTAs) can deep-link
    /// to a specific tab via `AppNavigation.shared.openInSettings(_:)`.
    /// Without an explicit binding TabView always lands on the first
    /// child — that's why early onboarding clicks felt broken
    /// (user wanted Summary, got Capture).
    @State private var settingsTab: SettingsTab = .general
    @Bindable private var nav = AppNavigation.shared

    var body: some View {
        TabView(selection: $settingsTab) {
            generalTab
                .tag(SettingsTab.general)
                // "General" — catch-all for app-level prefs (audio I/O,
                // hotkey, calendar gating, screenshots, storage). Was
                // "Capture" while Notion/MCP/Integrations also lived in
                // Settings; after they moved to Connections the tab
                // drifted into general-prefs territory and the label
                // followed. Mic icon stays — most rows are still
                // audio-recording-adjacent.
                .tabItem { Label("General", systemImage: "mic") }
                .scrollContentBackground(.hidden)

            transcriptionTab
                .tag(SettingsTab.transcription)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .scrollContentBackground(.hidden)

            summaryTab
                .tag(SettingsTab.summary)
                .tabItem { Label("Summary", systemImage: "text.bubble") }
                .scrollContentBackground(.hidden)

            PermissionsView()
                .tag(SettingsTab.permissions)
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
                .scrollContentBackground(.hidden)

            // Integrations + MCP server promoted out of Settings into
            // the top-level `Connections` sidebar destination — see
            // `MainSection.connections` + `ConnectionsView`. Settings
            // is now narrowly about "how the recorder processes a
            // session", Connections is "where Daisy talks to other
            // systems". About also moved to its own sidebar entry.
        }
        // 2026-05-22 — there was a brief workaround that replaced
        // this TabView with a custom HStack of tab buttons on
        // macOS 26, after a tester crash that pointed at the
        // `SystemSegmentedControl → DesignLibrary` path. Reverted
        // when the crash turned out to correlate with low disk +
        // a partly-downloaded Whisper model on the tester's
        // machine, not the segmented control itself. 2026-05-28
        // briefly tried the same workaround again in build 38 after
        // a build 37 crash with NSSegmentedControl in the stack —
        // reverted again in build 39 after observing the crash
        // correlates with recording start/stop cycles (not tab
        // navigation), suggesting the NSSegmentedControl is the
        // pathway the layout pressure lands on, not the trigger.
        // Native chrome restored; root cause being chased
        // separately via the audio engine rebuild work.
        // Consume any one-shot deep-link from AppNavigation. Set on
        // appear (initial entry into Settings) AND on change (user
        // jumps from FirstRun while Settings sheet is already
        // mounted — rare but possible).
        .onAppear { consumePendingSettingsTab() }
        .onChange(of: nav.pendingSettingsTab) { _, _ in
            consumePendingSettingsTab()
        }
        // macOS Settings convention: ~700pt fixed-width per tab. Without
        // a minimum the form collapses and Hotkey rows cramp horizontally.
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .task { await summarizer.refreshAvailability() }
    }

    /// Pull any one-shot Settings-tab request from AppNavigation,
    /// apply it to local TabView selection, and clear the field so
    /// it doesn't fire again on subsequent appears. This is the
    /// hand-off that makes FirstRun CTAs land on the right tab
    /// instead of the default Capture.
    private func consumePendingSettingsTab() {
        guard let pending = nav.pendingSettingsTab else { return }
        settingsTab = pending
        nav.pendingSettingsTab = nil
    }

    /// Label shown on the preset Menu's trigger. Always reflects
    /// the currently-active shortcut — whether it's a canonical
    /// preset or a custom combo the user recorded via Press keys.
    /// "Custom · ⌥⌘X" makes the state legible at a glance; if
    /// nothing is configured (`.none`), fall back to a hint.
    private var presetMenuLabel: String {
        let current = settings.recordHotkey
        if current.keyCode == nil {
            return "Choose preset"
        }
        if current.isPreset {
            return current.label
        }
        return "Custom — \(current.label)"
    }

    /// Combined recorder + preset-menu editor for ANY hotkey
    /// binding. Recorder handles regular keys + Fn rising edge;
    /// the preset menu is the bullet-proof way to pick Fn, bare
    /// F-keys, or canonical combos without arguing with macOS
    /// event delivery. Pre-1.0.3 only the meeting hotkey had the
    /// preset menu — voice-note and dictation rows offered only
    /// the recorder, which was a dead end for Fn (Fn never fires
    /// .keyDown so the recorder silently ignored it).
    /// One row in the Shortcuts section: title + per-row caption +
    /// the hotkey editor on the trailing side. Per-row caption beats
    /// the prior one-paragraph footer because each shortcut has
    /// different semantics — having "Voice note saves to Notes,
    /// dictation auto-pastes" jammed into a single wall of text
    /// made all three modes feel interchangeable.
    @ViewBuilder
    private func shortcutRow(
        title: String,
        caption: String,
        binding: Binding<HotkeyChoice>
    ) -> some View {
        LabeledContent {
            hotkeyEditor(binding: binding)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func hotkeyEditor(binding: Binding<HotkeyChoice>) -> some View {
        HStack(spacing: 8) {
            HotkeyRecorder(value: binding)
            Menu {
                ForEach(HotkeyChoice.allPresets) { preset in
                    Button {
                        binding.wrappedValue = preset
                    } label: {
                        // Fn preset gets the SF Symbol globe icon
                        // — matches the modern Mac keyboard glyph
                        // for the same key (kVK_Function).
                        if preset.isFnOnly {
                            Label(preset.label, systemImage: preset == binding.wrappedValue ? "checkmark" : "globe")
                        } else if preset == binding.wrappedValue {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                // Chevron-down reads as "this is a dropdown picker"
                // — the prior `list.bullet` icon was easy to misread
                // as a hamburger menu (i.e. "more actions") and
                // testers tried right-clicking it. Chevron matches
                // the rest of the macOS dropdown idiom.
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick from presets")
        }
    }

    // MARK: - MCP summarizer wrapper presets

    /// Known local-LLM MCP wrappers. Each defines a sensible
    /// `(baseURL, toolName, argumentsTemplate)` triple so the user
    /// can pick from a Menu instead of hand-writing JSON.
    private enum MCPSummarizerPreset {
        case ollama
        case lmStudio
        case llamaCpp

        var baseURL: String {
            switch self {
            case .ollama:   return "http://127.0.0.1:11435"
            case .lmStudio: return "http://127.0.0.1:1234"
            case .llamaCpp: return "http://127.0.0.1:8080"
            }
        }
        var toolName: String {
            switch self {
            case .ollama, .lmStudio: return "chat"
            case .llamaCpp:          return "complete"
            }
        }
        var template: String {
            switch self {
            case .ollama:
                return """
                {
                  "model": "qwen2.5:7b-instruct",
                  "messages": [
                    {"role": "system", "content": "{{system}}"},
                    {"role": "user", "content": "{{transcript}}"}
                  ],
                  "format": "json"
                }
                """
            case .lmStudio:
                return """
                {
                  "model": "qwen2.5-7b-instruct",
                  "messages": [
                    {"role": "system", "content": "{{system}}"},
                    {"role": "user", "content": "{{transcript}}"}
                  ],
                  "response_format": {"type": "json_object"}
                }
                """
            case .llamaCpp:
                return """
                {
                  "prompt": "{{system}}\\n\\n{{transcript}}",
                  "n_predict": 1024,
                  "temperature": 0.2
                }
                """
            }
        }
    }

    private func applyMCPSummarizerPreset(_ preset: MCPSummarizerPreset) {
        settings.mcpSummarizerURL = preset.baseURL
        settings.mcpSummarizerToolName = preset.toolName
        settings.mcpSummarizerArgumentsTemplate = preset.template
    }

    // MARK: - Storage (sessions folder)

    /// Row showing the currently-configured sessions folder + buttons
    /// to change or reset it. `storageRefreshTick` is bound to the
    /// HStack via `.id(...)` — that both reads the @State (so
    /// SwiftUI tracks it) and forces a fresh view identity each time
    /// the tick changes, which is exactly what we need since
    /// SessionsFolder reads UserDefaults directly (not @Observable).
    @ViewBuilder
    private var storageRow: some View {
        // 2026-05-25 — leading icons removed from all four Storage rows
        // (folder / clock.arrow.circlepath / trash / doc.text). Egor's
        // call: with row titles already strong ("Sessions folder",
        // "Delete audio after", "Clear all audio now", "Notion") the
        // icons were decoration, not navigation, and they pushed the
        // titles' x-position 28pt to the right vs the header text on
        // the same Form. Cleaner without them.
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions folder")
                    .font(.callout.weight(.medium))
                Text(storageDisplayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Choose folder…") {
                    if SessionsFolder.presentPicker() != nil {
                        storageRefreshTick &+= 1
                        ToastCenter.shared.show("New recordings will land here.", style: .success)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                if SessionsFolder.hasUserFolder {
                    // Was .borderless + tertiary grey — read as plain
                    // text, not as an actionable control. Promoted to
                    // .bordered with primary tint so it sits visually
                    // adjacent to Choose folder… as a peer secondary
                    // action.
                    Button("Reset to default") {
                        SessionsFolder.clearUserFolder()
                        storageRefreshTick &+= 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
            }
        }
        .id(storageRefreshTick)
    }

    private var storageDisplayPath: String {
        SessionsFolder.userFolderDisplayPath()
            ?? SessionsFolder.defaultContainerLabel
    }

    /// Caption under "Delete audio after" — flips wording per option
    /// so the user reads the right justification for whichever mode
    /// they've chosen. "After transcription" needs a different
    /// sentence than "24 hours" (no time-based framing makes sense).
    /// All variants honor the no-trailing-period brand rule.
    private var retentionCaptionText: String {
        switch settings.audioRetentionDays {
        case AppSettings.audioRetentionDoNotRecord:
            return "Audio never touches your disk. Daisy transcribes from the live mic stream and discards each buffer as soon as it's been through Whisper. Strongest privacy posture — but if Daisy crashes mid-meeting, the transcript is lost too, and you can't re-run transcription with a better model later. Transcripts, summaries and screenshots still save normally"
        case AppSettings.audioRetentionDeleteAfterTranscription:
            return "Audio deletes as soon as the transcript and summary are written. Transcripts, summaries and screenshots stay forever — audio is the heavy part"
        case 0:
            return "Daisy never deletes audio. Transcripts, summaries and screenshots also stay forever"
        default:
            return "Daisy deletes the audio recording once a session is this old. Transcripts, summaries and screenshots stay forever — audio is the heavy part"
        }
    }

    // MARK: - Notion destination (under Storage)

    /// Notion destination row + auto-send toggle + DisclosureGroup
    /// containing the credentials, parent picker, and Test connection
    /// affordances. Lives next to `storageRow` because Notion is the
    /// same logical category — "where Daisy sends a finished meeting"
    /// — as the local sessions folder. Pre-1.0.5 this was a separate
    /// tab inside the Connections sidebar destination; testers found
    /// it hard to discover because they'd think of "where sessions
    /// go" as a single concept and end up looking in Settings first.
    /// "Clear audio cache" affordance — manual flush of all `.caf`
    /// audio archives across every session, regardless of the
    /// retention picker setting. Lives below the retention row so
    /// the user gets both the auto-trim and the one-shot
    /// "everything off the disk now" controls in the same place.
    /// Existing users who installed before audio retention shipped
    /// might have multi-GB caches; the row caption shows the
    /// current size so they can decide before clicking. Confirm
    /// alert prevents accidental purges — transcripts and
    /// summaries are NOT touched, but raw audio is unrecoverable
    /// once removed.
    @ViewBuilder
    private var clearAudioCacheRow: some View {
        let mb = Double(audioCacheBytes) / 1_048_576.0
        // 2026-05-25 UX-copy pass:
        //   - "across N file(s)" with parenthesised plural-s reads
        //     sloppy at N=1 ("1 file(s)") and was the most visible
        //     copy nit in any screenshot of this row. Switched to a
        //     proper singular/plural switch + middle dot (matches
        //     menu-bar formatting elsewhere in the app).
        //   - "Nothing to clear" stays as-is — fine.
        //   - "file" → "recording" — the user thinks of these as
        //     meeting recordings, not files. Same reason "cache" got
        //     dropped from the row title (dev word).
        let sizeText: String = {
            if audioCacheFiles == 0 { return "Nothing to clear" }
            let noun = audioCacheFiles == 1 ? "recording" : "recordings"
            let size: String
            if mb < 1024 { size = String(format: "%.0f MB", mb) }
            else { size = String(format: "%.2f GB", mb / 1024.0) }
            return "\(size) · \(audioCacheFiles) \(noun)"
        }()
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Title weight bumped to .callout.medium for parity
                // with the other row titles in this Section
                // (Sessions folder / Notion). Without it the row
                // visually deemphasised itself, like an info row
                // instead of an actionable one.
                Text("Clear all audio now")
                    .font(.callout.weight(.medium))
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 2026-05-25 — dropped `role: .destructive` on the row
            // trigger. The role forces a system tint that renders
            // muddy peach in `.disabled` state on the cream / ivory
            // surface, and `role` overrides any explicit `.tint`
            // we set. Pre-fix the disabled button visually clashed
            // with the rest of the Section (toggles + secondary
            // buttons). Now: explicit red tint only when the action
            // is actually available; secondary grey when disabled.
            // The destructive intent still gets surfaced — inside
            // the confirm alert, where it belongs. This matches the
            // pattern in Linear / Things / Reeder where destructive
            // red lives in the confirm sheet, not the row trigger.
            // Also: "Clear…" → "Clear" — ellipsis = "more input
            // needed" per macOS HIG (file picker, text entry, etc).
            // A y/n confirm alert isn't more input, so the trailing
            // dot was just noise.
            Button {
                showingClearAudioConfirm = true
            } label: {
                if clearingAudioCache {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Clear")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(audioCacheFiles == 0 ? Color.secondary : Color.red)
            .disabled(clearingAudioCache || audioCacheFiles == 0)
        }
        .task(id: audioCacheRefreshTick) {
            let result = await AudioRetentionSweep.currentCacheSize()
            audioCacheFiles = result.files
            audioCacheBytes = result.bytes
        }
        // 2026-05-25 alert copy rewrite:
        //   - "archives" → "recordings" (archive reads cold and
        //     mirrors the same backend-y term we got rid of in the
        //     row title).
        //   - alert message dropped `microphone.caf` /
        //     `system_audio.caf` filenames entirely — pure
        //     engineering leak, users don't know those names.
        //   - confirm button "Clear" → "Delete" to match the new
        //     alert title verb (consistency: title says delete,
        //     button says delete).
        //   - "Cleared X of audio" toast → "Freed X" — shorter,
        //     reads as a user benefit (space back) rather than
        //     restating the action.
        //   - "Audio cache was already empty" → "Nothing to clear —
        //     audio is already gone" mirrors the row caption when
        //     idle so the language is consistent before/after.
        .alert("Delete all audio recordings?", isPresented: $showingClearAudioConfirm) {
            Button("Delete", role: .destructive) {
                clearingAudioCache = true
                AudioRetentionSweep.runNow { _, freedBytes in
                    let mb = Double(freedBytes) / 1_048_576.0
                    let freedText: String = {
                        if mb < 1024 { return String(format: "%.0f MB", mb) }
                        return String(format: "%.2f GB", mb / 1024.0)
                    }()
                    ToastCenter.shared.show(
                        freedBytes > 0
                            ? "Freed \(freedText)"
                            : "Nothing to clear — audio is already gone",
                        style: .success
                    )
                    clearingAudioCache = false
                    audioCacheRefreshTick += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Daisy deletes the audio from every session right now. Transcripts, summaries and screenshots stay. This can't be undone.")
        }
    }

    @ViewBuilder
    private var notionDestinationRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Notion")
                        .font(.callout.weight(.medium))
                    notionStatusBadge
                }
                Text(notionRowCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Gear opens the modal with secret / parent-id / parent-
            // type / Test connection. Pre-1.0.5.4 those lived in an
            // inline DisclosureGroup, which pushed Storage section
            // down and left a visible empty row when collapsed.
            Button {
                showingNotionSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Notion settings")
            Toggle("", isOn: $settings.autoSendNotion)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!settings.hasNotionCredentials || settings.lastNotionTestPassedAt == nil)
                .help(notionToggleHelp)
        }
        .sheet(isPresented: $showingNotionSettings) {
            notionSettingsSheet
                .frame(minWidth: 520, minHeight: 460)
        }

        // Folder filter — appears when auto-send is on, so a power
        // user can scope auto-push to e.g. "Work" folder and keep
        // personal voice notes off Notion.
        if settings.autoSendNotion {
            folderFilterPicker(
                title: "Only from folders",
                selection: Binding(
                    get: { settings.autoSendNotionFolders },
                    set: { settings.autoSendNotionFolders = $0 }
                )
            )
        }
    }

    /// Modal sheet with the full Notion configuration — secret,
    /// parent id, parent type, Test connection. Replaced the prior
    /// inline DisclosureGroup in 1.0.5.4. Keeps the Storage section
    /// tight and pushes the field wall out of the main settings
    /// scroll, which matches what users expect from a macOS sheet.
    @ViewBuilder
    private var notionSettingsSheet: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notion")
                                .font(.headline)
                            Text("Send finished sessions into a Notion page or database.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        notionStatusBadge
                    }

                    LabeledContent {
                        SecureField("", text: $settings.notionToken, prompt: Text("secret_…"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity)
                    } label: {
                        labelWithCaption("Integration secret",
                                         caption: "Paste your Notion integration secret.")
                    }

                    LabeledContent {
                        TextField("", text: $settings.notionParentID, prompt: Text("a1b2c3d4…"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity)
                    } label: {
                        labelWithCaption("Parent ID",
                                         caption: "The 32-character ID at the end of the page or database URL — with or without dashes.")
                    }

                    LabeledContent {
                        // pickerStyle(.menu) instead of .segmented:
                        // macOS 26.2 ships an Apple-side UAF in the Swift
                        // concurrency ↔ AppKit bridge that crashes any
                        // SwiftUI Picker(.segmented) on layout (it routes
                        // through SystemSegmentedControl, an NSSegmentedControl
                        // wrapper — same UAF family as the NavigationSplitView
                        // sidebar toggle we removed in build 33). 2 options
                        // fit the menu naturally in this LabeledContent
                        // trailing slot. Restore .segmented post-26.x once
                        // Apple ships the fix.
                        Picker("", selection: $settings.notionParentKind) {
                            Text("Page").tag("page")
                            Text("Database").tag("database")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } label: {
                        labelWithCaption("Parent type",
                                         caption: "Page — Daisy adds the session as a child page underneath. Database — adds a row (title column must be named \"Name\").")
                    }

                    HStack {
                        notionTestStatusView
                        Spacer()
                        Button("Test connection") {
                            Task { await testNotion() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.daisyAccent)
                        .disabled(notionTestResult == .testing || !settings.hasNotionCredentials)
                    }

                    Text("Make an internal integration at notion.so/profile/integrations, then share the parent page or database with it. Test creates a probe page you can delete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    showingNotionSettings = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .background(Color.daisyBgPrimary)
    }

    /// Right-of-title badge — same vocabulary as the old section
    /// header in Connections so returning users recognise the state.
    @ViewBuilder
    private var notionStatusBadge: some View {
        if settings.hasNotionCredentials && settings.lastNotionTestPassedAt != nil {
            Text("Connected")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.daisySuccess)
        } else if settings.hasNotionCredentials {
            Text("Needs test")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.daisyWarning)
        }
    }

    /// Caption text under the Notion title — flips depending on
    /// config state. Three meaningful states: unconfigured (call to
    /// action), configured-but-untested (warning to test first),
    /// configured-and-tested (passive confirmation).
    private var notionRowCaption: String {
        // 2026-05-25 — UX copy pass found that two of these strings
        // referenced "below", which was true when the Notion deep
        // config lived in a DisclosureGroup right under this row.
        // The 1.0.5.4 move pulled that config into a modal sheet
        // opened from a gear button on the same row, so "below"
        // became factually wrong — there is no longer anything
        // below to configure. Rewritten to point at the gear, and
        // verb-aligned across the three states ("send" vs the old
        // mixed "push" / "pushes").
        if !settings.hasNotionCredentials {
            return "Send finished sessions to Notion as a child page or a database row. Set it up in the gear."
        }
        if settings.lastNotionTestPassedAt == nil {
            return "Run Test connection in the gear first — auto-send only turns on once it passes."
        }
        return "Sends each session to Notion the moment you stop recording."
    }

    private var notionToggleHelp: String {
        if !settings.hasNotionCredentials {
            return "Open Notion settings in the gear first."
        }
        if settings.lastNotionTestPassedAt == nil {
            return "Run Test connection before enabling auto-send."
        }
        return "Auto-send finished sessions to Notion."
    }

    @ViewBuilder
    private var notionTestStatusView: some View {
        switch notionTestResult {
        case .idle:             StatusBadge(state: .idle)
        case .testing:          StatusBadge(state: .busy)
        case .success(let m):   StatusBadge(state: .ok, message: m)
        case .failure(let m):   StatusBadge(state: .err, message: m)
        }
    }

    private func testNotion() async {
        notionTestResult = .testing
        let probe = MeetingExportData(
            title: "Daisy — Connection test",
            summary: nil,
            transcriptChunks: ["This page was created by Daisy as a connection test. You can safely delete it."],
            durationSeconds: 0,
            locale: "en",
            startedAt: Date()
        )
        do {
            let url = try await NotionExporter.shared.createMeetingPage(probe)
            notionTestResult = .success("Test page created in Notion.")
            // Mark proven-working — the auto-send toggle's enabled
            // gate flips only after this timestamp exists.
            settings.lastNotionTestPassedAt = Date()
            NSWorkspace.shared.open(url)
        } catch {
            notionTestResult = .failure("Couldn't reach Notion — \(error.localizedDescription)")
        }
    }

    /// Folder-filter picker for "Only from folders" — visible only
    /// when auto-send is ON. Multi-select via Menu so the row stays
    /// compact regardless of how many folders the user has.
    @ViewBuilder
    private func folderFilterPicker(
        title: String,
        selection: Binding<Set<String>>
    ) -> some View {
        let folders = FolderStore.shared.allFolders
        Menu {
            Button {
                selection.wrappedValue = []
            } label: {
                if selection.wrappedValue.isEmpty {
                    Label("All folders", systemImage: "checkmark")
                } else {
                    Text("All folders")
                }
            }
            Divider()
            ForEach(folders) { folder in
                Button {
                    var current = selection.wrappedValue
                    if current.contains(folder.slug) {
                        current.remove(folder.slug)
                    } else {
                        current.insert(folder.slug)
                    }
                    selection.wrappedValue = current
                } label: {
                    if selection.wrappedValue.contains(folder.slug) {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(folderFilterSummary(selection.wrappedValue, allFolders: folders))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func folderFilterSummary(_ slugs: Set<String>, allFolders: [SessionFolder]) -> String {
        if slugs.isEmpty { return "All folders" }
        let names = allFolders.filter { slugs.contains($0.slug) }.map(\.name)
        if names.count == 1 { return names[0] }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.count) folders"
    }

    /// Label + caption stacked vertically in the LEADING column of
    /// a `LabeledContent` row. Keeps the input alone in the
    /// trailing column — which (1) lets every trailing field share
    /// the same width regardless of caption length, and (2) lets a
    /// segmented Picker stay on the same row as its label instead
    /// of falling into Form's two-line fallback.
    @ViewBuilder
    private func labelWithCaption(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Integrations (Notion + MCP destinations + default-destination
    // picker) and the MCP server tab live in the `Connections`
    // sidebar destination — see ConnectionsView.swift. The helpers
    // that supported them (testNotion, integrationRow, mcpStatusRow,
    // folderFilterPicker, autoSendNotionCaption, …) live alongside
    // them there. Calendar behaviour toggles came back to Settings →
    // General in 1.0.4, sitting next to the auto-start trigger they
    // conceptually neighbour; the EventKit grant + status badge are
    // in Settings → Permissions.

    // MARK: - General

    private var generalTab: some View {
        generalTabForm
            .task { refreshMicDevices() }
    }

    private var generalTabForm: some View {
        Form {
            // ── Group 0: Profile ──────────────────────────────
            // Identity used to label the mic-side of transcripts.
            // Empty by default → falls back to the generic "Me".
            // First section in General because it answers the
            // narrative question "who am I in this app" before
            // "what mic, where files, etc.". Section was originally
            // "You" — renamed to "Profile" to match the macOS
            // Settings convention (System Settings → Privacy & Security
            // → "Profiles", Mail → "Profiles"), which reads as a
            // labelled identity container rather than a pronoun.
            Section {
                // 2026-05-25 — caption ("Replaces \"Me\" in transcripts
                // and lets the summarizer address you by name") removed.
                // The label "Your name" + the placeholder "e.g. Egor"
                // already carry intent for anyone scanning Settings;
                // the longer rationale moved to a tooltip on a
                // post-PH polish if it turns out we need it. Dropping
                // the caption also kills Form's auto-inserted row
                // separator since the Section now has a single row —
                // no more half-divider underneath the field.
                LabeledContent("Your name") {
                    TextField("", text: $settings.userDisplayName, prompt: Text("e.g. Egor"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Profile")
            }

            // ── Group 1: Audio & devices ──────────────────────
            // What's coming in and what cues the user hears.
            // Mic picker + system-audio toggle + sound cues fit
            // under one mental model ("audio I/O of the recorder").
            Section {
                micPickerRow
                Toggle(isOn: $settings.captureSystemAudio) {
                    Text("Capture system audio")
                    Text("Records the other side of meetings (Zoom, Meet, Telegram). macOS will ask for Screen & System Audio Recording permission the first time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.recordingSoundsEnabled) {
                    Text("Play sound on start, pause, and stop")
                    Text("Quiet macOS system sounds (Tink / Pop / Glass) on recording transitions. Volume tuned so the cue doesn't get picked up by your own mic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio & devices")
            }

            // ── Group 2: Storage ──────────────────────────────
            // Two destinations live side-by-side: the on-disk folder
            // (Daisy/Sessions) and an optional Notion push. They're
            // the same logical category ("where finished meetings
            // go") so keeping them in one Section is the right
            // mental model. Notion's deep config (secret + parent ID
            // + test) hides in a DisclosureGroup so the row isn't
            // overwhelming for users who'll never wire Notion up.
            Section {
                storageRow
                // 2026-05-25 footer rewrite — old "Older recordings
                // stay where they were" got misread by testers as
                // "old recordings will be deleted." New phrasing
                // makes the future-vs-already-recorded split
                // explicit, and tightens the inventory list at the
                // same time.
                Text("Future recordings land in a `Daisy/Sessions` folder here — audio, transcripts, summaries and screenshots together. Anything you've already recorded stays where it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Retention picker — wrapped in the same HStack +
                // leading-icon shape as `storageRow` /
                // `clearAudioCacheRow` / `notionDestinationRow`.
                // Pre-2026-05-25 this used a stock `Picker(label:
                // VStack(...))` with no leading icon, which broke
                // the row rhythm in this Section (folder icon /
                // [nothing] / trash icon / doc icon). Now every
                // row carries an 18pt leading icon, the section
                // reads as one cohesive list. Icon
                // `clock.arrow.circlepath` is the SF Symbols
                // vocabulary for retention / TTL / auto-erase —
                // the same glyph macOS Mail uses for its
                // auto-erase preference.
                //
                // Caption also rewrites — old version leaked the
                // `.caf` filename (engineering noise users don't
                // care about). New version names what changes on
                // disk without the implementation detail.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete audio after")
                            .font(.callout.weight(.medium))
                        Text(retentionCaptionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // 2026-05-25 — added "After transcription" as the
                    // first option (tag = sentinel -1). New-install
                    // default per AppSettings. Per-session purge fires
                    // from RecordingSession.finalizePostStop once the
                    // pipeline is done with the audio — no timer
                    // involved. Existing "24h / 7d / 30d / Forever"
                    // options preserved so power users (legal,
                    // journalists, anyone who re-summarizes from
                    // audio later) keep the same control they had.
                    Picker("", selection: $settings.audioRetentionDays) {
                        // Don't record at all — strongest privacy
                        // posture, pattern (d) from the 2026-05-28
                        // competitor audit. Whisper still works
                        // (live in-memory PCM stream), the on-disk
                        // .caf archive is just skipped. Trade-off:
                        // no crash recovery, no re-transcription
                        // later. Aimed at users in regulated
                        // environments and the "I just want
                        // notes, not recordings" majority.
                        Text("Don't record audio")
                            .tag(AppSettings.audioRetentionDoNotRecord)
                        Text("After transcription")
                            .tag(AppSettings.audioRetentionDeleteAfterTranscription)
                        Text("24 hours").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Keep forever").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: settings.audioRetentionDays) { _, new in
                        // Apply immediately so the user sees disk freed
                        // without waiting for next launch. -1 is a
                        // per-session mode (kicks in on the next
                        // finished session); runIfNeeded no-ops it
                        // safely — past sessions aren't surprise-
                        // deleted, the user can hit Clear if they
                        // want a hard reset.
                        AudioRetentionSweep.runIfNeeded(retentionDays: new)
                    }
                }

                clearAudioCacheRow

                // Dropped explicit Divider() that used to sit
                // between clearAudioCacheRow and notionDestinationRow
                // — Form's native row separators are enough, and the
                // extra divider was reading as an "empty content gap"
                // visually (Egor flagged 2026-05-25). Once we split
                // this Section into "Sessions folder" / "Send to"
                // (post-launch refactor) the separator becomes a
                // proper Section gap automatically.

                notionDestinationRow
            } header: {
                Text("Storage")
            }

            // ── Group 3a: Shortcuts ───────────────────────────
            // Three independent hotkeys — one per recording mode.
            // Each row offers BOTH the recorder ("Press keys…")
            // and a preset Menu — the preset is the only way to
            // bind Fn / 🌐 globe, F-keys without conflicts, etc.
            // without fighting macOS event delivery quirks.
            Section {
                shortcutRow(
                    title: "Record a meeting",
                    caption: "Tap once to start, tap again to pause / resume.",
                    binding: $settings.recordHotkey
                )
                shortcutRow(
                    title: "Voice note",
                    caption: "Tap once to start, tap again to stop. Saves into Notes, no LLM summary.",
                    binding: $settings.voiceNoteHotkey
                )
                shortcutRow(
                    title: "Dictation (hold)",
                    caption: "Hold to talk, release to paste. Needs Accessibility permission.",
                    binding: $settings.dictationHotkey
                )
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Combos must include ⌘ / ⌃ / ⌥, a bare function key (F1–F20), or the globe Fn key.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── Group 3b: Meetings ────────────────────────────
            // One block for everything about how meetings start /
            // stop / surface. Pre-1.0.5.5 this was three separate
            // sections (Auto-start, After Stop, Calendar) — same
            // mental model, fragmented across the form. Unified
            // under a single "Meetings" header now.
            //
            // Auto-start trigger from meeting-app launch is the only
            // path that doesn't need calendar access — kept at the
            // top so it doesn't grey out with the calendar gate.
            Section {
                Toggle(isOn: $settings.autoStartOnMeeting) {
                    Text("Start when a meeting app opens")
                    Text("Begins recording when Zoom, Teams, Webex, Telegram or Discord launches. Apps already open when Daisy starts are left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.autoStartFromCalendar) {
                    Text("Start at the scheduled meeting time")
                    Text("Reads your calendar, finds events with a Zoom/Meet/Teams/Webex link, starts recording when they begin. Up to 2 min late is fine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource)

                Toggle(isOn: $settings.autoStopFromCalendar) {
                    Text("Stop when the event ends")
                    Text("Daisy hits Stop & save at the event's end time plus a grace period. A toast 30 s before lets you keep going.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource)

                if settings.autoStopFromCalendar {
                    Picker("Grace period", selection: $settings.autoStopGraceSec) {
                        Text("On the dot").tag(0)
                        Text("1 min").tag(60)
                        Text("2 min").tag(120)
                        Text("5 min").tag(300)
                        Text("10 min").tag(600)
                        Text("15 min").tag(900)
                        Text("30 min").tag(1800)
                        Text("1 hour").tag(3600)
                    }
                    .pickerStyle(.menu)
                    .disabled(!hasAnyCalendarSource)
                }

                Toggle(isOn: $settings.menuBarShowsNextMeeting) {
                    Text("Show next meeting in the menu bar")
                    Text("Adds the next event's time + title (\"14:30 · Q3 Review\") next to Daisy's menu-bar icon. Hidden during recording so the active session stays the focus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource)

                Toggle(isOn: $settings.showSessionAfterStop) {
                    Text("Open the session window when recording stops")
                    Text("Switches to History and shows the just-recorded session the moment you stop. The transcript is visible immediately; the summary fades in as soon as the LLM finishes (usually 15–30 seconds).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Meetings")
            } footer: {
                if !hasAnyCalendarSource {
                    Text("Calendar-based toggles need access in Settings → Permissions. Daisy reads via macOS EventKit, which picks up iCloud, Exchange, and any Google accounts you've added to Calendar.app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Calendar source: macOS EventKit — picks up iCloud, Exchange, and any Google accounts you've added to Calendar.app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // ── Group 4: While recording ──────────────────────
            // What Daisy does and surfaces during a session beyond
            // notifications. Floating widget visibility, screenshots.
            // (Notifications were pulled out into their own Section
            // in 1.0.5 so the user can per-toggle the three banner
            // classes from one place.)
            Section {
                Toggle(isOn: $settings.floatingWidgetEnabled) {
                    Text("Show floating recorder on top of other windows")
                    Text("Small mark above your apps while recording. Tap to pause; right-click for Stop & save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.screenshotsEnabled) {
                    Text("Capture screenshots periodically")
                    Text("Useful for tracking shared screens or slides. Saved alongside the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.screenshotsEnabled {
                    Stepper(value: $settings.screenshotIntervalSec, in: 15...600, step: 15) {
                        HStack {
                            Text("Every")
                            Text("\(settings.screenshotIntervalSec) s")
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("While recording")
            }

            // ── Group 5: Notifications ────────────────────────
            // Per-class toggles for every macOS banner Daisy posts.
            // Surface the user can flip individual notifications off
            // without affecting the rest — common case is "I want
            // auto-start confirmation but the silence prompt feels
            // nannying", or vice versa.
            Section {
                Toggle(isOn: $settings.notifyOnAutoStart) {
                    Text("Recording started")
                    Text("Banner when a calendar event auto-starts Daisy. Includes a Stop & save action if you didn't want that meeting tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.notifyOnAutoStop) {
                    Text("Meeting ended — saved")
                    Text("Confirmation banner when the calendar event ends and Daisy auto-stops + saves the recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.silencePromptsEnabled) {
                    Text("Long silence")
                    Text("After 3 min of silence (or 5 min on pause) Daisy asks whether to keep going. Includes Stop & save / Keep recording actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("macOS-level banners. You can also tune Daisy's notification style in System Settings → Notifications → Daisy.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Auto-summary lives in the Summary tab — it sits next
            // to the provider config it depends on.
        }
        .formStyle(.grouped)
    }

    // Microphone selector row in the General tab. Empty UID == follow
    // the macOS system default (the v1.0 behaviour). For the default
    // option we suffix the name of the device currently in that slot
    // so the user knows what "system default" actually resolves to
    // right now ("System default (AirPods Pro)") — far more useful
    // than a bare "System default" label.
    @ViewBuilder
    private var micPickerRow: some View {
        // 2026-05-25 — pre-fix this row carried a manual re-scan
        // button (`arrow.trianglehead.2.clockwise` glyph next to the
        // Picker) and a one-line explainer caption. Both removed:
        //   • Re-scan: redundant — Daisy already observes CoreAudio
        //     device changes via `refreshMicDevices()` on form load,
        //     and AVAudioSession route-change notifications keep
        //     `micDevices` live. The button only existed as a paranoid
        //     fallback that never fired in practice; visual clutter on
        //     a row that's a single picker.
        //   • Caption ("Daisy uses this device for the microphone
        //     track. Pick \"System default\" to follow your macOS Sound
        //     settings."): the LabeledContent label "Microphone" and
        //     the explicit "System default (…)" option name carry
        //     enough intent for anyone scanning Settings. The longer
        //     "what System default does" explanation isn't load-
        //     bearing — picker behaviour is obvious on tap.
        LabeledContent("Microphone") {
            Picker("", selection: $settings.selectedMicDeviceUID) {
                Text(systemDefaultLabel).tag("")
                if !micDevices.isEmpty {
                    Divider()
                    ForEach(micDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                // If the saved UID isn't in the live list (device
                // unplugged since selection), include a disabled
                // placeholder so the Picker can still display the
                // current value rather than silently snapping to
                // System default. The user sees that something is
                // missing and can act on it.
                if !settings.selectedMicDeviceUID.isEmpty,
                   !micDevices.contains(where: { $0.uid == settings.selectedMicDeviceUID }) {
                    Divider()
                    Text("Saved device (not connected)")
                        .tag(settings.selectedMicDeviceUID)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var systemDefaultLabel: String {
        if let current = micDevices.first(where: { $0.isSystemDefault }) {
            return "System default (\(current.name))"
        }
        return "System default"
    }

    private func refreshMicDevices() {
        micDevices = AudioInputDevices.list()
    }

    /// At least one calendar source is connected — Apple EventKit
    /// (`.fullAccess` granted) OR Google via direct OAuth. Gates the
    /// behaviour toggles in the Calendar section of generalTab; the
    /// underlying grant/connect affordances live elsewhere
    /// (EventKit in Settings → Permissions, Google in Connections
    /// once verification clears).
    ///
    /// Reads the LIVE `CalendarService.authorizationStatus`, not the
    /// persisted `settings.calendarAccessGranted` cache. Pre-1.0.4 the
    /// gate used the cached bool, which could lag behind the real
    /// EventKit state — a tester with Apple Calendar granted in
    /// System Settings → Privacy & Security but a stale UserDefaults
    /// bool saw every toggle in this section disabled even though
    /// Permissions tab correctly said "Granted". Same observable
    /// (`@Bindable var calendarService = CalendarService.shared`) the
    /// Permissions tab reads, so the two surfaces can't diverge.
    private var hasAnyCalendarSource: Bool {
        systemPermissions.calendar == .granted || googleAccount.isConnected
    }

    // MARK: - Transcription (Whisper)

    private var transcriptionTab: some View {
        Form {
            Section {
                Picker("Model", selection: $whisper.modelID) {
                    ForEach(WhisperEngine.availableModels, id: \.id) { model in
                        Text("\(model.label) · \(model.sizeMB) MB")
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)

                // Status row inline with the picker — mirrors the
                // Summary section's "Available · Refresh" layout so
                // both transcription + summary preferences feel
                // identical structurally. Pre-1.0.5.5 Model status
                // lived in its own Section below Language, which
                // visually divorced "what model" from "is it ready".
                HStack(spacing: 8) {
                    StatusBadge(state: whisperBadgeState, message: whisperStatusText)
                    Spacer()
                    Button("Reload") { Task { await whisper.reload() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.daisyTextPrimary)
                        .disabled(isWhisperLoading)
                }
                whisperStatusBody

                Text("Whisper runs on-device. Bigger models handle accents and multilingual meetings better, at the cost of disk and a bit of speed. First time you pick a model, Daisy downloads it from Hugging Face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Model")
            }

            // Diarization above Language in 1.0.6: it's a structural
            // "how is the audio interpreted" choice, same family as
            // Model — Language is downstream content-level. Sized
            // down the description too; the long version moved to
            // the footer.
            Section {
                // 2026-05-25 — primary "Speakers mode" picker added in
                // 1.0.7. Two modes:
                //  • Split (true, default) = current behavior;
                //    pyannote diarizes the system stream into separate
                //    Remote A / Remote B / Remote C clusters.
                //  • Two sides (false) = Granola-style. System stream
                //    gets a single "Remote" label regardless of how
                //    many voices. Mic stream is still "you".
                // 2026-05-26 — renamed "All speakers" → "Split" to
                // match the verb form of the action ("split each
                // voice into its own row") and pair-cadence-wise
                // with "Two sides" (1-2 syllables each).
                // Strings consolidated to EN in 1.0.7 — the picker
                // shipped briefly with RU radio labels + EN section
                // chrome, which broke the language rhythm of the rest
                // of the Whisper form. Whole form is EN, so are these.
                // Caption under the picker and the section footer
                // were both removed shortly after: both quoted the
                // "Two sides" label literally, which read like a live
                // status of which mode was active and contradicted
                // the actual selection (e.g. radio on "All speakers"
                // with caption "Pick 'Two sides' if…" feels like a
                // bug to the user even when the copy is descriptive).
                // The option names alone are self-explanatory; no
                // example-name parenthesis either — they overloaded
                // the row with internal-jargon proper nouns.
                // pickerStyle(.radioGroup) instead of .inline:
                // macOS 26.2 ships an Apple-side UAF in the Swift
                // concurrency ↔ AppKit bridge that crashes SwiftUI
                // Picker(.inline) on macOS — .inline routes through
                // SystemSegmentedControl (NSSegmentedControl wrapper),
                // same UAF family as the NavigationSplitView sidebar
                // toggle we removed in build 33. Reproduced on build 36
                // when the user hit start → silent recording → restart
                // and the picker re-laid out mid-cycle. .radioGroup uses
                // real NSButtons (NOT NSCell-backed), which is the only
                // discrete-select macOS picker style not on any 26.x UAF
                // stack. Visual change: stacked radios instead of a
                // segmented row — actually reads more "settings" anyway.
                //
                // Labels renamed 2026-05-28 from "Split"/"Two sides" to
                // "Per speaker"/"Me vs. others" because the original
                // labels collided with the sidebar's "Recording both
                // sides" status pill — a user reported the conflict in
                // the same crash thread. New labels describe what shows
                // up in the transcript (per-speaker rows vs. just me
                // and everyone-else) without borrowing "sides" vocab.
                Picker(selection: $settings.diarizeRemoteSpeakers) {
                    Text("Per speaker")
                        .tag(true)
                    Text("Me vs. others")
                        .tag(false)
                } label: {
                    Text("Speakers in transcript")
                }
                .pickerStyle(.radioGroup)

                Toggle(isOn: $settings.diarizeMicrophone) {
                    Text("Diarize microphone too")
                    Text("Splits voices in your mic into Speaker A / B instead of one \"Me\". Use when remote people are heard through your speakers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.suppressAcousticEcho) {
                    Text("Suppress acoustic echo")
                    Text("Drops mic-side lines that look like echoes of the remote audio (happens when you play meetings through speakers instead of headphones). Sequential matches in a 2-second window — single quoted lines are kept")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Diarization")
            }

            Section {
                Toggle(isOn: $settings.liveTranscriptionEnabled) {
                    Text("Show transcript live during meeting")
                    Text("OFF runs Whisper as a single pass on Stop instead of every ~2s during recording. Lighter on long meetings — pause/resume stays instant on 1h+ sessions and the daisy widget never stutters. Trade-off: toolbar transcript stays empty until you press Stop. Dictation always uses live regardless of this switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Live transcription")
            }

            Section {
                Picker("Meetings (default)", selection: $settings.defaultTranscriptionLocale) {
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)
                Picker("Voice notes", selection: $settings.voiceNoteLocale) {
                    Text("Same as meetings").tag("")
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)
                Picker("Dictation", selection: $settings.dictationLocale) {
                    Text("Same as meetings").tag("")
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)
                Text("Pick a specific language to kill the kind of language drift that produces hallucinated phrases in another tongue. Voice notes and dictation inherit the Meetings default unless you set them explicitly — useful if you record meetings in English but dictate personal notes in Russian. Per-session override is still available in the recorder header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language")
            }

            // Model status was its own Section here in 1.0.5.4 —
            // 1.0.5.5 inlined the badge + Reload into the Model
            // section above for parity with Summary's layout.

            Section {
                modelsCacheRow
            } header: {
                Text("Cache")
            } footer: {
                Text("Switching to a different model downloads it alongside the previous one — old files aren't deleted automatically so a downgrade is instant. Use Remove unused to free disk space.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Known speakers — persistent voice profiles store. Lets
            // the user inspect what biometric derivatives Daisy has
            // saved, forget individual profiles, or wipe the whole
            // store. This is a privacy-required surface — without it
            // there's no way to delete enrollment data short of
            // resetting the app container.
            Section {
                speakerProfilesRow
            } header: {
                Text("Known speakers")
            } footer: {
                Text("After you name a speaker in a transcript (e.g. \"Alex\"), Daisy stores a short voice fingerprint locally and auto-labels them in future recordings. Fingerprints never leave your Mac. Forget anytime.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task(id: cacheRefreshTick) {
            // Refresh on tab open + after any cleanup. Detached so
            // a slow FileManager scan never blocks the form's
            // first paint.
            cachedModelsCount = await Task.detached { WhisperEngine.cachedModels().count }.value
            cachedModelsBytes = await Task.detached { WhisperEngine.totalCacheSizeBytes() }.value
        }
    }

    /// Models-on-disk summary row + Remove-unused action. Disabled
    /// when there's only one cached variant (current one), so the
    /// button never appears actionable when there's nothing it
    /// could do.
    @ViewBuilder
    private var modelsCacheRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models on disk")
                Text("\(cachedModelsCount) \(cachedModelsCount == 1 ? "model" : "models") · \(formattedCacheSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Remove unused") {
                Task {
                    let freed = await whisper.removeUnusedModels()
                    cacheRefreshTick &+= 1
                    if freed > 0 {
                        ToastCenter.shared.show(
                            "Freed \(byteFormatter.string(fromByteCount: freed)) of model cache.",
                            style: .success
                        )
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.daisyTextPrimary)
            .disabled(cachedModelsCount <= 1 || isWhisperLoading)
        }
    }

    private var formattedCacheSize: String {
        byteFormatter.string(fromByteCount: cachedModelsBytes)
    }

    /// Bind directly to the singleton so the row re-renders when the
    /// store mutates (forget, upsert, etc.). Lifecycle-attached to
    /// the view; no need to retain elsewhere.
    @Bindable private var speakerStore = SpeakerProfileStore.shared

    /// Lists every known speaker profile in most-recently-seen order
    /// with per-row "Forget" + a global "Forget all" button. Hides
    /// gracefully when no profiles exist so first-time users don't
    /// see an empty placeholder card.
    @ViewBuilder
    private var speakerProfilesRow: some View {
        let profiles = speakerStore.profilesByRecent
        if profiles.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                Text("No voice profiles yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .onAppear { speakerStore.ensureLoaded() }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .foregroundStyle(Color.daisyAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.callout.weight(.medium))
                            Text(speakerProfileSummary(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("Forget") {
                            speakerStore.forget(profile.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.daisyTextPrimary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Forget all") {
                        speakerStore.forgetAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyError)
                }
            }
        }
    }

    private func speakerProfileSummary(_ profile: SpeakerProfile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let seen = formatter.localizedString(for: profile.lastSeenAt, relativeTo: Date())
        let count = profile.sessionCount
        let meetings = count == 1 ? "1 meeting" : "\(count) meetings"
        return "\(meetings) · last \(seen)"
    }

    private var whisperBadgeState: StatusBadge.State {
        switch whisper.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    private var whisperStatusText: String {
        switch whisper.state {
        case .ready: return "Ready"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading model…"
        case .failed: return "Failed"
        case .notLoaded: return "Not loaded"
        }
    }

    @ViewBuilder
    private var whisperStatusBody: some View {
        switch whisper.state {
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                Text("\(Int(p * 100))% of model downloaded — keep the app open until it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading(let status):
            Text(status).font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.secondary)
        case .ready:
            Text("Model: \(whisper.modelID)").font(.caption).foregroundStyle(.secondary)
        case .notLoaded:
            EmptyView()
        }
    }

    private var isWhisperLoading: Bool {
        switch whisper.state {
        case .loading, .downloading: return true
        default: return false
        }
    }

    // MARK: - Summary Provider

    private var summaryTab: some View {
        Form {
            // ONE-block summary section: Provider → credentials →
            // Model → Status → Test. Eliminates the stack of 4–5
            // small sections with redundant headers ("Summary
            // provider", "Anthropic API key", "Model", "Provider
            // status") that fragmented what is conceptually a
            // single setup flow. Caption rolls into one footer
            // explaining where transcripts go for the selected
            // provider.
            Section {
                Picker("Provider", selection: $summarizer.providerKind) {
                    ForEach(availableSummaryProviders, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .onAppear {
                    // If a user upgraded TO macOS 26 with an old
                    // setting OR is downgrading from 26 with
                    // .appleIntelligence stuck in UserDefaults,
                    // bounce them onto a valid provider so the
                    // picker doesn't render an unreachable selection.
                    if !availableSummaryProviders.contains(summarizer.providerKind),
                       let firstAvailable = availableSummaryProviders.first {
                        summarizer.providerKind = firstAvailable
                    }
                }

                providerInlineRows

                // Status row — inline so the user sees
                // "this provider, with these creds, is reachable"
                // without scrolling.
                HStack(spacing: 8) {
                    StatusBadge(state: summarizerBadgeState, message: summarizerStatusText)
                    Spacer()
                    Button("Refresh") {
                        Task { await summarizer.refreshAvailability() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }

                // Test row — final action in the block. Apple
                // Intelligence has nothing to validate remotely so
                // we skip it for that provider.
                if summarizer.providerKind != .appleIntelligence {
                    HStack {
                        Button("Test summary") {
                            Task { await testSummaryProvider() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.daisyAccent)
                        .disabled(testSummaryButtonDisabled)
                        Spacer()
                        summaryTestStatusView
                    }
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(summarySectionFooter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // MCP-only extras stay separate — preset menu + raw
            // JSON template are an engineering escape hatch most
            // users never open.
            if summarizer.providerKind == .mcp {
                mcpPresetSection
                mcpAdvancedJSONSection
            }

            // Preview MD-document after a successful Test summary.
            summaryTestPreviewSection

            Section {
                Picker("Summary language", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.id)
                    }
                }
                .pickerStyle(.menu)
                Text("The summary will always be written in this language, even if the meeting itself was in another. Handy when you record in one language and send the follow-up in another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Summary language")
            }

            Section {
                Toggle(isOn: $settings.autoSummarize) {
                    Text("Summarize when recording stops")
                    Text("Runs the selected provider on the transcript the moment you stop — meeting overview, next actions, and a follow-up draft for clients or partners.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!summarizerAvailable)
                if !summarizerAvailable {
                    Text("Provider isn’t ready yet — set it up in the section above first.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                }
            } header: {
                Text("Auto-summary")
            }
        }
        .formStyle(.grouped)
    }

    /// Inline credential / model rows for the selected provider.
    /// Lives inside the unified Summary section so picker → keys →
    /// model render as one visual block. Apple Intelligence has no
    /// inline rows (nothing to configure).
    @ViewBuilder
    private var providerInlineRows: some View {
        switch summarizer.providerKind {
        case .appleIntelligence:
            EmptyView()

        case .anthropic:
            LabeledContent("API key") {
                SecureField("", text: $settings.anthropicAPIKey, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.anthropicModel) {
                ForEach(AnthropicAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.menu)

        case .openai:
            LabeledContent("API key") {
                SecureField("", text: $settings.openaiAPIKey, prompt: Text("sk-proj-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.openaiModel) {
                ForEach(OpenAIAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.menu)

        case .ollama:
            LabeledContent("Server URL") {
                TextField("", text: $summarizer.ollamaBaseURL, prompt: Text(OllamaAPISummarizer.defaultBaseURLString))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.ollamaModel) {
                ForEach(OllamaAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                // Free-form fallback — user may have pulled a model
                // we don't list (custom fine-tunes, latest tags etc.).
                // tag("") keeps the picker from rejecting an unknown
                // current value; the inline TextField below is the
                // real authoring surface for off-list IDs.
                if !OllamaAPISummarizer.availableModels.contains(where: { $0.id == summarizer.ollamaModel }) {
                    Text("Custom: \(summarizer.ollamaModel)").tag(summarizer.ollamaModel)
                }
            }
            .pickerStyle(.menu)
            LabeledContent("Model tag") {
                TextField("", text: $summarizer.ollamaModel, prompt: Text(OllamaAPISummarizer.defaultModelID))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }

        case .lmStudio:
            LabeledContent("Server URL") {
                TextField("", text: $summarizer.lmStudioBaseURL, prompt: Text(LMStudioAPISummarizer.defaultBaseURLString))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.lmStudioModel) {
                ForEach(LMStudioAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                if !LMStudioAPISummarizer.availableModels.contains(where: { $0.id == summarizer.lmStudioModel }) {
                    Text("Custom: \(summarizer.lmStudioModel)").tag(summarizer.lmStudioModel)
                }
            }
            .pickerStyle(.menu)
            LabeledContent("API identifier") {
                TextField("", text: $summarizer.lmStudioModel, prompt: Text(LMStudioAPISummarizer.defaultModelID))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }

        case .mcp:
            // `prompt:` (placeholder) + `labelsHidden()` so Form
            // doesn't promote the title to a trailing accessory and
            // draw it twice. Same fix we apply in the Notion section.
            LabeledContent("Server URL") {
                TextField("", text: $settings.mcpSummarizerURL, prompt: Text("http://127.0.0.1:11435"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            LabeledContent("Tool name") {
                TextField("", text: $settings.mcpSummarizerToolName, prompt: Text("chat"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// SummaryProviderKind cases visible to the user on the current
    /// macOS version. Apple Intelligence is hidden on macOS 14/15
    /// because its underlying framework (FoundationModels) only
    /// exists from Tahoe onward — surfacing it on Sonoma would
    /// show a control that has no working code path behind it.
    private var availableSummaryProviders: [SummaryProviderKind] {
        if #available(macOS 26.0, *) {
            return SummaryProviderKind.allCases
        }
        return SummaryProviderKind.allCases.filter { $0 != .appleIntelligence }
    }

    /// Single Test-button enable rule across all providers — saves
    /// duplicating the same `||`-chain in each switch case.
    private var testSummaryButtonDisabled: Bool {
        if summaryTestResult == .testing { return true }
        switch summarizer.providerKind {
        case .appleIntelligence: return true
        case .anthropic: return settings.anthropicAPIKey.isEmpty
        case .openai: return settings.openaiAPIKey.isEmpty
        case .ollama: return summarizer.ollamaBaseURL.isEmpty || summarizer.ollamaModel.isEmpty
        case .lmStudio: return summarizer.lmStudioBaseURL.isEmpty || summarizer.lmStudioModel.isEmpty
        case .mcp:
            return settings.mcpSummarizerURL.isEmpty
                || settings.mcpSummarizerToolName.isEmpty
        }
    }

    /// Per-provider footer copy for the unified Summary section.
    /// Rolls "where transcripts go" + "where to get keys" + "cost"
    /// into one paragraph so the user doesn't read four scattered
    /// captions.
    private var summarySectionFooter: String {
        switch summarizer.providerKind {
        case .appleIntelligence:
            return "Runs entirely on-device. Nothing about the transcript leaves your Mac. Apple's local model doesn't support every language (e.g. Russian) — for those, switch to a cloud provider."
        case .anthropic:
            return "Transcripts are sent to Anthropic over HTTPS using your own API key. Create one at console.anthropic.com/settings/keys — it's stored in your macOS Keychain. Each summary costs roughly $0.01–0.05."
        case .openai:
            return "Transcripts are sent to OpenAI over HTTPS using your own API key. Create one at platform.openai.com/api-keys — it's stored in your macOS Keychain. Each summary costs roughly $0.01–0.05."
        case .ollama:
            return "Daisy calls your local Ollama server (`ollama serve`) over its native `/api/chat` REST. No API key, no network egress — everything stays on your Mac. Pull the model first: `ollama pull \(OllamaAPISummarizer.defaultModelID)`. Free."
        case .lmStudio:
            return "Daisy calls your local LM Studio server over its OpenAI-compatible `/v1/chat/completions` REST. No API key, no network egress — everything stays on your Mac. Load a model in the LM Studio app and click Developer → Start. The API identifier in this picker must match the one LM Studio shows under the loaded model. Free."
        case .mcp:
            return "Advanced — for users running a custom MCP server (Python shim, `mcp-ollama` wrapper, etc.). Daisy connects over HTTP+SSE and calls one tool per summary. For stock Ollama or LM Studio use their dedicated providers above instead — those work without an MCP shim."
        }
    }

    /// Quick-setup preset menu — MCP only, kept as its own section
    /// because it's an escape hatch most users skip.
    private var mcpPresetSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Use template for")
                Spacer()
                Menu("Pick wrapper") {
                    Button("llama.cpp (complete tool)") {
                        applyMCPSummarizerPreset(.llamaCpp)
                    }
                    // Ollama + LM Studio presets removed in build 40:
                    // those products don't speak MCP+SSE natively, so
                    // the preset's URL/tool/template would silently
                    // fail at first summary. Stock Ollama and LM Studio
                    // each have their own dedicated provider above
                    // (Settings → Summary → Provider) that hits their
                    // real REST endpoint directly. MCP preset list now
                    // shows only wrappers that genuinely DO expose an
                    // MCP-over-SSE surface.
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("Fills the URL, tool name, and arguments template with sensible defaults for that wrapper. For stock Ollama or LM Studio, switch the provider above instead — those have dedicated adapters that work without an MCP shim.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Quick setup")
        }
    }

    /// Raw JSON template editor — engineering escape hatch.
    private var mcpAdvancedJSONSection: some View {
        Section {
            DisclosureGroup("Advanced — raw JSON template") {
                TextEditor(text: $settings.mcpSummarizerArgumentsTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )
                HStack {
                    Button("Reset to default") {
                        settings.mcpSummarizerArgumentsTemplate = MCPSummarizer.defaultArgumentsTemplate
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                    Spacer()
                }
                Text("JSON template for the tool's `arguments`. Three placeholders get substituted before sending: `{{system}}` (Daisy's system prompt), `{{transcript}}` (meeting title + body), `{{title}}` (meeting title alone). Edit the `model` field to match a model your wrapper has pulled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarizerBadgeState: StatusBadge.State {
        switch summarizer.availability {
        case .available: return .ok
        case .unavailable: return .warn
        case .unknown: return .busy
        }
    }

    private var summarizerStatusText: String {
        switch summarizer.availability {
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }

    private var summarizerStatusBody: String {
        switch summarizer.availability {
        case .available: return "\(summarizer.providerKind.shortName) is ready for summaries."
        case .unavailable(let reason): return reason
        case .unknown: return ""
        }
    }

    private var summarizerAvailable: Bool {
        if case .available = summarizer.availability { return true }
        return false
    }

    private var summaryTestStatusView: some View {
        switch summaryTestResult {
        case .idle:        StatusBadge(state: .idle)
        case .testing:     StatusBadge(state: .busy)
        case .success(let msg): StatusBadge(state: .ok, message: msg)
        case .failure(let msg): StatusBadge(state: .err, message: msg)
        }
    }

    /// Inline preview that shows what the rendered summary looks
    /// like after a successful Test summary. Mirrors the typography
    /// SessionDetailView uses for real sessions — same MD-document
    /// grammar (H3 heading + hairline + body) so the test result
    /// reads as a faithful demo of "this is what you'll see after
    /// a real meeting".
    @ViewBuilder
    private var summaryTestPreviewSection: some View {
        if let preview = summaryTestPreview {
            // Headers in the user's chosen summary language — so a
            // Russian summary preview shows "Встреча / Следующие
            // шаги / Ответ клиенту" instead of English structural
            // labels stamped on top of Russian content. The picker
            // value goes through SummaryLanguage.id which matches
            // SummaryLabels.for's expected codes; "auto" → English.
            let labels = SummaryLabels.for(language: settings.summaryLanguage)
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup {
                        Text(Self.fixtureTranscript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Text("Test transcript (\(Self.fixtureTitle))")
                            .font(.caption.weight(.medium))
                    }

                    Divider()

                    previewMDSection(title: labels.meeting) {
                        Text(preview.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Granola-style topical outline — 3-5 sections,
                    // each with a flat (or shallow-nested) bullet
                    // list. Mirrors the real session detail layout
                    // so the preview faithfully demos what a session
                    // looks like after a real meeting. Pre-1.0.2 the
                    // preview only rendered Meeting + Next actions +
                    // Follow-up, so a Granola-style summary looked
                    // like a single paragraph here even when the
                    // model returned sections.
                    ForEach(Array(preview.sections.enumerated()), id: \.offset) { _, section in
                        previewMDSection(title: section.title) {
                            previewBulletTree(section.bullets, level: 0)
                        }
                    }

                    if !preview.actionItems.isEmpty {
                        previewMDSection(title: labels.nextActions) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(preview.actionItems.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "square")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Text(item)
                                            .font(.callout)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if !preview.clientFollowUp.isEmpty {
                        previewMDSection(title: labels.followUp) {
                            Text(preview.clientFollowUp)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Preview · what a real session looks like")
            }
        }
    }

    /// Recursive bullet renderer for the Settings → Test summary
    /// preview. Mirrors `SessionDetailView.bulletTree` typography so
    /// the preview reads as a faithful demo of a real session. Uses
    /// `AnyView` rather than `some View` to break the same recursive-
    /// opaque-return-type compiler error that bit us in
    /// ContentView/SessionDetailView during the Xcode 16 / Swift 6
    /// upgrade — see [[fix-recursive-viewbuilder-bulletTree]].
    private func previewBulletTree(_ bullets: [SummaryBullet], level: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(width: 8, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bullet.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !bullet.children.isEmpty {
                                previewBulletTree(bullet.children, level: level + 1)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(level) * 14)
                }
            }
        )
    }

    @ViewBuilder
    private func previewMDSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.daisyTextPrimary)
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(height: 0.5)
            content()
        }
    }

    private func testSummaryProvider() async {
        summaryTestResult = .testing
        summaryTestPreview = nil
        // Use the isolated `runProbe` path — calling the regular
        // `summarize` would write into the shared singleton's
        // `lastSummary` / `lastError`, which the active recording
        // session reads back as if it were the real summary for
        // that meeting. Bug reproduced when the user pressed Test
        // summary mid-recording and the fixture transcript ended
        // up attached to the live session.
        //
        // Honour the user's Summary-language picker: if they chose
        // a specific language, force the probe to output in that
        // language so they see what their real summaries will look
        // like. "Auto" passes nil so the model picks based on the
        // (English) fixture content — fine for the smoke test
        // semantics ("can my provider produce a summary at all").
        // Pre-fix this hard-coded `localeHint: "en"` made the test
        // always read English even when the picker said "Русский",
        // which looked like a localization bug to QA.
        let chosenHint: String? = (settings.summaryLanguage == SummaryLanguage.auto.id)
            ? nil
            : settings.summaryLanguage
        do {
            let summary = try await summarizer.runProbe(
                transcript: Self.fixtureTranscript,
                title: Self.fixtureTitle,
                localeHint: chosenHint
            )
            summaryTestResult = .success("Summary came through.")
            summaryTestPreview = summary
        } catch {
            // Wrap the raw error — system messages from URLSession /
            // CoreData / decoder show up here looking like "The
            // request timed out." with no context. Prefixing keeps
            // the diagnostic info but anchors it to a recognisable
            // verb ("Test failed"), so the user knows where to
            // look without parsing system-level English.
            summaryTestResult = .failure("Test failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Test fixture
    //
    // Realistic two-person client call so the model has actual
    // material to summarise — a couple of concrete next actions,
    // one decision, and an obvious follow-up to send to the
    // client. Renders into a populated MeetingSummary the preview
    // can show as a "this is what a finished session looks like"
    // demo right inside Settings.

    private static let fixtureTitle = "Brand site · homepage direction review"

    private static let fixtureTranscript = """
    [you] Thanks for jumping on. I pulled together two directions for the homepage hero based on what you mentioned last week. Want to walk through them?
    [client] Yeah, let's do it. I want to know which one we're locking in before I show the team on Friday.
    [you] OK. Direction one leans into the product photography — big image, very little copy. Direction two is more editorial: copy-first, the product appears lower down the fold.
    [client] I like the editorial one. We get more room for the value prop. But honestly, the product photo on direction one is much stronger than what we have today.
    [you] Right. What if we keep the editorial structure but commission a couple of fresh product shots for it? Say two scenes — one lifestyle, one studio.
    [client] That works for me. Can you scope what a new shoot would cost and send a number by Thursday? I'd rather not be guessing on budget when I'm in front of the team.
    [you] Will do — I'll have a quote in your inbox Thursday morning. Quick check: what about the testimonials section? You mentioned wanting to feature the new enterprise quote.
    [client] Yes, please include it. I'll send you the approved version tonight.
    [you] Perfect. So to recap: we go with the editorial direction, you send the testimonial tonight, I send a shoot budget Thursday, and we lock the homepage layout on the call next Tuesday.
    [client] Great. Let's also book 30 minutes Friday to look at the mobile breakpoints — I have a couple of concerns there I want to flag before they freeze.
    [you] Done. I'll send the invite right after this call.
    """

    // MARK: - About

    // About content lives in `AboutView.swift` — promoted out of
    // Settings tabs into a top-level sidebar section.
}

#Preview {
    SettingsView(settings: AppSettings())
}
