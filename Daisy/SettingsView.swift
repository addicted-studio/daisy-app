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
    @Bindable var parakeet = ParakeetEngine.shared
    @Bindable var nemotron = NemotronLiveEngine.shared
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
    // Notion destination config (token / parent / auto-send / Test
    // connection) moved to the top-level Connections page →
    // Auto-routing tab in 1.0.7.16 — it's an external send-to
    // destination, the same class as the MCP integrations that
    // already live there, not local recorder behaviour. Its @State
    // (notionTestResult / showingNotionSettings), views, and helpers
    // now live in ConnectionsView. The shared `TestResult` enum was
    // hoisted to file scope (bottom of this file) so both this view's
    // Summary test and Connections' Notion test can reference it.

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
    /// True when "Remove unused" has something to free: >1 Whisper variant,
    /// or a Parakeet model on disk that dictation isn't currently using.
    @State private var hasUnusedModels = false
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
    /// Live `/api/tags` model list for the Ollama picker (empty until
    /// fetched / when the server is unreachable → static catalog).
    @State private var ollamaInstalledModels: [String] = []
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
                .tabItem { Label("General", systemImage: "gearshape") }
                .scrollContentBackground(.hidden)

            recordingTab
                .tag(SettingsTab.recording)
                .tabItem { Label("Recording", systemImage: "mic") }
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
                Text("Recordings folder")
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

    // Notion destination (row + auto-send toggle + folder filter +
    // the credentials/parent/Test-connection sheet) moved to the
    // top-level Connections page → Auto-routing tab in 1.0.7.16 —
    // it's an external send-to destination, the same class as the MCP
    // integrations already there, not local recorder behaviour. The
    // views (notionDestinationRow / notionSettingsSheet /
    // notionStatusBadge / notionTestStatusView), copy (notionRowCaption
    // / notionToggleHelp), the testNotion() probe, and the
    // folder-filter + labelWithCaption helpers that only Notion used
    // now live in ConnectionsView. Calendar behaviour toggles came
    // back to Settings → General in 1.0.4, sitting next to the
    // auto-start trigger they conceptually neighbour; the EventKit
    // grant + status badge are in Settings → Permissions.

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

            // (Audio/mic, Shortcuts, Meetings, and the floating widget
            // moved to the new "Recording" tab in 1.0.7.16. General is now
            // app-level prefs: Profile, Storage, Privacy, Notifications.)

            // ── Group 2: Storage / Privacy ────────────────────
            // Split (1.0.7.16) from one "Storage" section that conflated
            // three things: where files live, the retention/privacy
            // choice, and the optional Notion export.
            Section {
                storageRow
                clearAudioCacheRow
            } header: {
                Text("Storage")
            }

            Section {
                // Retention / privacy posture. "Don't record audio" is the
                // strongest stance; the rest are a time-to-live. Per-session
                // purge fires from RecordingSession.finalizePostStop; the
                // time options are swept by AudioRetentionSweep.
                HStack(alignment: .center, spacing: 10) {
                    Text("Delete audio after")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("", selection: $settings.audioRetentionDays) {
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
                        AudioRetentionSweep.runIfNeeded(retentionDays: new)
                    }
                }
            } header: {
                Text("Privacy")
            }

            // (Notion "Send to" moved to the Connections page in 1.0.7.16
            // — it's an external destination, not local storage. Shortcuts
            // and Meetings moved to the new "Recording" tab.)

            // ── Notifications ─────────────────────────────────
            // Per-class toggles for every macOS banner Daisy posts.
            // Surface the user can flip individual notifications off
            // without affecting the rest — common case is "I want
            // auto-start confirmation but the silence prompt feels
            // nannying", or vice versa.
            Section {
                // Sound cues on start/pause/stop. Moved here from "Audio &
                // devices" in 1.0.7.16 (the only audio cue, fits with the
                // notification toggles).
                Toggle("Notification sounds", isOn: $settings.recordingSoundsEnabled)

                Toggle(isOn: $settings.notifyOnAutoStart) {
                    Text("Recording started")
                    Text("When a meeting auto-starts, with a Stop & save action.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.notifyOnAutoStop) {
                    Text("Meeting ended — saved")
                    Text("When a meeting auto-stops and saves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.silencePromptsEnabled) {
                    Text("Long silence")
                    Text("After a long quiet stretch, asks whether to keep going.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notifications")
            }

            // Auto-summary lives in the Summary tab — it sits next
            // to the provider config it depends on.
        }
        .formStyle(.grouped)
    }

    // MARK: - Recording tab (split out of General, 1.0.7.16)

    private var recordingTab: some View {
        recordingTabForm
            .task { refreshMicDevices() }
    }

    private var recordingTabForm: some View {
        Form {
            // ── Audio input ───────────────────────────────────
            Section {
                micPickerRow
            } header: {
                Text("Audio")
            }

            // ── Shortcuts ─────────────────────────────────────
            // One hotkey per recording mode. Each row offers the
            // recorder ("Press keys…") AND a preset Menu — the preset is
            // the only reliable way to bind Fn / 🌐 / F-keys on macOS.
            Section {
                shortcutRow(
                    title: "Record a meeting",
                    caption: "Tap once to start, tap again to pause / resume",
                    binding: $settings.recordHotkey
                )
                shortcutRow(
                    title: "Voice note",
                    caption: "Tap once to start, tap again to stop",
                    binding: $settings.voiceNoteHotkey
                )
                shortcutRow(
                    title: "Dictation",
                    caption: "Hold to talk, release to paste",
                    binding: $settings.dictationHotkey
                )
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcuts")
                    Text("Combos must include ⌘ / ⌃ / ⌥, a bare function key (F1–F20), or the globe Fn key.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                }
            }

            // ── Meetings ──────────────────────────────────────
            Section {
                Picker("Auto-record", selection: $settings.autoStartPolicy) {
                    ForEach(AutoStartPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Record the other side", isOn: $settings.captureSystemAudio)

                // Applies to every recording (not just meetings) → ungated,
                // above the calendar-only row.
                Toggle("Open the session window when recording stops", isOn: $settings.showSessionAfterStop)

                // Calendar-only. Merged on/off + grace: -1 → off, 0 → stop
                // at the scheduled end, 300 → 5 min after (the grace also
                // doubles as the rejoin window).
                Picker("Stop when the meeting ends", selection: autoStopSelection) {
                    Text("Off").tag(-1)
                    Text("At the scheduled end").tag(0)
                    Text("5 minutes after").tag(300)
                }
                .pickerStyle(.menu)
                .disabled(!hasAnyCalendarSource)

                // Rides on the auto-stop row above: when ON, the
                // silence-gated stop asks first (macOS banner with
                // Stop & save / 10 / 30 more minutes + an in-app
                // toast) instead of counting down and stopping on
                // its own. Greyed out while auto-stop itself is off.
                Toggle(isOn: $settings.autoStopPromptMode) {
                    Text("Ask before auto-stopping")
                    Text("Notification with Stop & save / snooze options instead of stopping on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasAnyCalendarSource || !settings.autoStopFromCalendar)
            } header: {
                Text("Meetings")
            } footer: {
                if !hasAnyCalendarSource {
                    Text("Calendar-based options need access in Settings → Permissions. Daisy reads via macOS Calendar — iCloud, Exchange, and any Google accounts you've added to Calendar.app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // ── Menu bar & widget ─────────────────────────────
            // Daisy's on-screen presence. (Floating widget moved here from
            // "Audio & devices"; "Show next meeting" from "Meetings" — both
            // are about how visible Daisy is, not audio I/O.)
            Section {
                Toggle("Floating widget", isOn: $settings.floatingWidgetEnabled)
                Toggle("Show next meeting in the menu bar", isOn: $settings.menuBarShowsNextMeeting)
                    .disabled(!hasAnyCalendarSource)
            } header: {
                Text("Menu bar & widget")
            } footer: {
                if !hasAnyCalendarSource {
                    Text("Showing the next meeting needs calendar access in Settings → Permissions.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
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

    /// One selector standing in for the old auto-stop toggle + grace
    /// picker. -1 = off; otherwise on, with the value as the grace (also
    /// the rejoin window). A stored grace that isn't one of the offered
    /// options shows as "5 minutes after" until the user re-picks.
    private var autoStopSelection: Binding<Int> {
        Binding(
            get: {
                guard settings.autoStopFromCalendar else { return -1 }
                return settings.autoStopGraceSec == 0 ? 0 : 300
            },
            set: { newValue in
                if newValue < 0 {
                    settings.autoStopFromCalendar = false
                } else {
                    settings.autoStopFromCalendar = true
                    settings.autoStopGraceSec = newValue
                }
            }
        )
    }

    // MARK: - Transcription (Whisper)

    private var transcriptionTab: some View {
        Form {
            // One "Transcription" block, two rows. Friendly names (no model
            // IDs / engine vendor names), no helper captions, no separate
            // status rows or buttons — each row's status (and model download
            // progress) rides as a badge next to its label. Meetings (+
            // voice notes) always use the Whisper model on row 1; dictation
            // picks its engine on row 2 (Default = Whisper, reusing that
            // model; Faster = on-device Parakeet, ~600 MB once).
            Section {
                Picker(selection: $whisper.modelID) {
                    ForEach(WhisperEngine.availableModels, id: \.id) { model in
                        let size = model.sizeMB >= 1000
                            ? String(format: "%.1f GB", Double(model.sizeMB) / 1000.0)
                            : "\(model.sizeMB) MB"
                        let name = model.id == WhisperEngine.defaultModelID
                            ? "Standard" : "Most accurate"
                        Text("\(name) · \(size)").tag(model.id)
                    }
                } label: {
                    transcriptionRowLabel(
                        "Meeting model",
                        state: whisperBadgeState,
                        message: whisperShortStatus
                    )
                }
                .pickerStyle(.menu)

                Picker(selection: $settings.dictationUseParakeet) {
                    Text("Standard").tag(false)
                    Text("Faster · 600 MB").tag(true)
                } label: {
                    transcriptionRowLabel(
                        "Dictation engine",
                        state: dictationBadgeState,
                        message: dictationShortStatus
                    )
                }
                .pickerStyle(.menu)
                // Selecting "Faster" (or reopening Settings while it's
                // already chosen) kicks the Parakeet download so its badge
                // shows progress — no separate button; the badge IS the
                // download indicator.
                .onChange(of: settings.dictationUseParakeet) { _, useParakeet in
                    if useParakeet { Task { await ParakeetEngine.shared.ensureLoaded() } }
                    // Re-scan models on disk now so the "Models" row and
                    // "Remove unused" reflect the new engine immediately
                    // (the Parakeet model becomes used/unused right away),
                    // instead of only after the next Settings open.
                    cacheRefreshTick &+= 1
                }
                .onChange(of: parakeet.isReady) { _, _ in
                    // Parakeet finished downloading/loading → refresh the
                    // models size + count without waiting for a reopen.
                    cacheRefreshTick &+= 1
                }
                .onAppear {
                    if settings.dictationUseParakeet, !parakeet.isReady {
                        Task { await ParakeetEngine.shared.ensureLoaded() }
                    }
                }

                // Streaming live preview for dictation (Nemotron 3.5,
                // on-device). The badge doubles as the model-download
                // indicator — same pattern as the Faster engine above.
                // Preview-only: the pasted text still comes from the
                // dictation engine picked above.
                Toggle(isOn: $settings.dictationUseNemotronLive) {
                    transcriptionRowLabel(
                        "Live preview while dictating",
                        state: nemotronBadgeState,
                        message: nemotronShortStatus
                    )
                }
                .help("Shows your words about half a second behind your speech while you hold the dictation key. The pasted text still comes from the dictation engine above. Turning this on downloads an on-device model once.")
                .onChange(of: settings.dictationUseNemotronLive) { _, useNemotron in
                    if useNemotron { Task { await NemotronLiveEngine.shared.ensureLoaded() } }
                }
                .onAppear {
                    if settings.dictationUseNemotronLive, !nemotron.isReady {
                        Task { await NemotronLiveEngine.shared.ensureLoaded() }
                    }
                }

                // One transcription language for everything (meetings,
                // voice notes, dictation). Per-mode overrides were removed
                // 2026-06-05 — nobody set them separately, and the recorder
                // header still offers a per-session override. Pinning a
                // language kills auto-detect drift (e.g. a Russian opener
                // mis-decoded as French). Voice-note / dictation locale
                // fields stay in the model defaulting to "inherit", so this
                // single pick drives all three modes.
                Picker("Language", selection: $settings.defaultTranscriptionLocale) {
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)

                // Live-transcript tier — how the toolbar transcript updates
                // during a meeting. Plain names: Default (was "Lite") is the
                // sensible default; Full is heavier; Off transcribes once on
                // Stop. The final saved transcript is always full quality,
                // and dictation always runs live regardless of this.
                Picker("Live transcript", selection: $settings.liveTranscriptionTier) {
                    Text("Off").tag(LiveTranscriptionTier.off)
                    Text("Standard").tag(LiveTranscriptionTier.lite)
                    Text("Full · uses more memory").tag(LiveTranscriptionTier.full)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Transcription")
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
                // pickerStyle(.menu): dropdowns (NSPopUpButton), matching
                // every other picker in this form (1.0.7.16 — was
                // .radioGroup). DO NOT switch these to .inline / .segmented:
                // that routes through NSSegmentedControl, which hits a macOS
                // 26.2 use-after-free in the Swift-concurrency↔AppKit bridge
                // and crashes when the picker re-lays-out mid-cycle (repro'd
                // build 36: start → silent recording → restart). Both .menu
                // (popup) and .radioGroup (real NSButtons) are off that UAF
                // stack; we use .menu for form consistency.
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
                    Text("Me and others")
                        .tag(false)
                } label: {
                    Text("Speakers in transcript")
                }
                .pickerStyle(.menu)

                // Moved in from the old "Speaker matching" section (merged
                // 1.0.7.16). Same .menu style as the rest of the form.
                Picker(selection: $settings.speakerMatchMode) {
                    ForEach(SpeakerMatchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Name known people")
                }
                .pickerStyle(.menu)
                Text(speakerMatchModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.diarizeMicrophone) {
                    Text("Split voices in my mic")
                    Text("When other people are heard through your speakers, label them separately instead of all as “Me.”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.suppressAcousticEcho) {
                    Text("Remove echo from my mic")
                    Text("Drops lines your mic catches as an echo when a meeting plays through your speakers instead of headphones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Speakers")
            }

            // "Match known speakers" moved into the merged "Speakers"
            // section above (1.0.7.16) as "Name known people".
            // "Models" cache section moved BELOW "Known speakers"
            // (1.0.7.16) — it's disk maintenance, was splitting the two
            // speaker sections.

            // Known speakers — persistent voice profiles store. Lets
            // the user inspect what biometric derivatives Daisy has
            // saved, edit a person's emails/notes, forget individual
            // profiles, or wipe the whole store. This is a privacy-
            // required surface — without it
            // there's no way to delete enrollment data short of
            // resetting the app container.
            Section {
                speakerProfilesRow
            } header: {
                Text("Known speakers")
            } footer: {
                Text("After you name a speaker in a transcript (e.g. \"Alex\"), Daisy stores a short voice fingerprint locally and auto-labels them in future recordings. Open a speaker to add their email (so calendar invites match them too) or notes. Fingerprints never leave your Mac. Forget anytime.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // On-disk model cache (maintenance) — kept last on the tab,
            // after the speaker content it used to interrupt.
            Section {
                modelsCacheRow
            } header: {
                Text("Models")
            }
        }
        .formStyle(.grouped)
        .task(id: cacheRefreshTick) {
            // Refresh on tab open + after any cleanup. Detached so a slow
            // FileManager scan never blocks the form's first paint. Counts
            // BOTH the Whisper models and the dictation engine (Parakeet)
            // model on disk.
            let w = await Task.detached {
                (WhisperEngine.cachedModels().count, WhisperEngine.totalCacheSizeBytes())
            }.value
            let p = await Task.detached {
                (ParakeetEngine.cachedModelCount(), ParakeetEngine.cachedModelBytes())
            }.value
            cachedModelsCount = w.0 + p.0
            cachedModelsBytes = w.1 + p.1
            hasUnusedModels = (w.0 > 1) || (p.0 > 0 && !settings.dictationUseParakeet)
        }
    }

    /// Models-on-disk summary row + Remove-unused action. Disabled
    /// when there's only one cached variant (current one), so the
    /// button never appears actionable when there's nothing it
    /// could do.
    @ViewBuilder
    private var modelsCacheRow: some View {
        HStack(spacing: 8) {
            Text("\(cachedModelsCount) \(cachedModelsCount == 1 ? "model" : "models") · \(formattedCacheSize)")
                .monospacedDigit()
            Spacer()
            Button("Remove unused") {
                Task {
                    var freed = await whisper.removeUnusedModels()
                    // The Parakeet model is "unused" when dictation isn't
                    // set to it — free it too.
                    if !settings.dictationUseParakeet {
                        freed += ParakeetEngine.removeCachedModel()
                    }
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
            .disabled(!hasUnusedModels || isWhisperLoading)
        }
    }

    private var formattedCacheSize: String {
        byteFormatter.string(fromByteCount: cachedModelsBytes)
    }

    /// Bind directly to the singleton so the row re-renders when the
    /// store mutates (forget, upsert, etc.). Lifecycle-attached to
    /// the view; no need to retain elsewhere.
    @Bindable private var speakerStore = SpeakerProfileStore.shared

    /// Profile the user tapped to inspect / edit. Drives the speaker
    /// detail sheet (emails, notes, "appears in"). nil = no sheet.
    /// We key off the UUID rather than holding the value type so the
    /// sheet always reads the freshest profile from the store after
    /// an edit, and so a Forget from inside the sheet can dismiss
    /// cleanly without a dangling stale copy. Wrapped in a tiny
    /// Identifiable box because UUID isn't Identifiable on its own and
    /// `.sheet(item:)` needs Identifiable (we avoid an app-wide
    /// `extension UUID: Identifiable`, which would risk a conflict).
    @State private var editingSpeaker: EditingSpeaker?

    /// Identifiable wrapper for the speaker-detail sheet's `item:`
    /// binding. `id` IS the profile UUID.
    private struct EditingSpeaker: Identifiable {
        let id: UUID
    }

    /// Per-mode explainer under the speaker-match picker — one sentence
    /// per mode in Daisy's plain voice. DEFAULT is Automatic — preserve
    /// the long-standing behaviour, so its copy reads as "the normal thing".
    private var speakerMatchModeHelp: String {
        switch settings.speakerMatchMode {
        case .automatic:
            return "Daisy labels a recognized person automatically as soon as a recording finishes — by their voice, or by their email if the meeting came from your calendar. This is the default."
        case .suggest:
            return "Daisy recognizes the person but waits — it shows the name as a suggestion in the recording's “Name the speakers” card, and you confirm before it's applied."
        case .off:
            return "Daisy never auto-labels across meetings. Speakers stay “Remote A / B” until you name them by hand. Voice fingerprints are still saved when you name someone, so you can switch this back on later."
        }
    }

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
                    // Whole row is a button into the detail sheet
                    // (emails / notes / appears-in). Forget stays a
                    // distinct trailing button so a mis-tap can't
                    // delete a profile — it's the only destructive
                    // action and it keeps its own hit target.
                    HStack(spacing: 10) {
                        Button {
                            editingSpeaker = EditingSpeaker(id: profile.id)
                        } label: {
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
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
            .sheet(item: $editingSpeaker) { item in
                SpeakerDetailSheet(profileID: item.id)
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

    /// Compact per-row status — a short word/percent for the badge that
    /// sits next to the "Meeting model" label (also the download indicator).
    /// `nil` when ready or not-yet-loaded → the badge shows just its icon.
    private var whisperShortStatus: String? {
        switch whisper.state {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Failed"
        case .ready, .notLoaded: return nil
        }
    }

    /// Row label = title + a status badge (which doubles as the model-
    /// download indicator). Shared by both Transcription rows.
    @ViewBuilder
    private func transcriptionRowLabel(_ title: String, state: StatusBadge.State, message: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
            StatusBadge(state: state, message: message)
        }
    }

    private var isWhisperLoading: Bool {
        switch whisper.state {
        case .loading, .downloading: return true
        default: return false
        }
    }

    // MARK: - Dictation engine (Parakeet)

    private var parakeetBadgeState: StatusBadge.State {
        switch parakeet.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    private var parakeetShortStatus: String? {
        switch parakeet.state {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Failed"
        case .ready, .notLoaded: return nil
        }
    }

    /// The dictation row's badge follows whichever engine is selected:
    /// Whisper → the Whisper model's state; Parakeet → Parakeet's.
    private var dictationBadgeState: StatusBadge.State {
        settings.dictationUseParakeet ? parakeetBadgeState : whisperBadgeState
    }

    private var dictationShortStatus: String? {
        settings.dictationUseParakeet ? parakeetShortStatus : whisperShortStatus
    }

    /// Streaming dictation preview (Nemotron). Badge mirrors the engine's
    /// load state; the download percentage doubles as the progress UI.
    private var nemotronBadgeState: StatusBadge.State {
        switch nemotron.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    private var nemotronShortStatus: String? {
        switch nemotron.state {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Failed"
        case .ready, .notLoaded: return nil
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
                        // Model-aware for Ollama: a `:cloud` model is not
                        // local, so the row reads "Ollama (cloud model)".
                        Text(kind.displayName(ollamaModel: kind == .ollama ? summarizer.ollamaModel : nil)).tag(kind)
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
                // Status (and its Refresh) ride at the header level, right-
                // aligned — same idea as the Transcription badges.
                HStack(spacing: 8) {
                    Text("Summary provider")
                    Spacer()
                    StatusBadge(state: summarizerBadgeState, message: summarizerStatusText)
                    Button("Refresh") {
                        Task { await summarizer.refreshAvailability() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summarySectionFooter)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    // When the provider can't run, surface the specific,
                    // actionable reason here (warning tint) instead of
                    // leaving the user with only the "Unavailable" badge.
                    if case .unavailable(let reason) = summarizer.availability {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(Color.daisyWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

                Toggle(isOn: $settings.autoSummarize) {
                    Text("Summarize when recording stops")
                }
                .disabled(!summarizerAvailable)
                if !summarizerAvailable {
                    Text("Provider isn’t ready yet — set it up above first.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                }
            } header: {
                Text("Summary output")
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
                ForEach(ollamaModelChoices, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                // Free-form fallback — the current value may not be in
                // the live list yet (just typed, or the server is down
                // and we're on the static catalog).
                if !ollamaModelChoices.contains(where: { $0.id == summarizer.ollamaModel }) {
                    Text("Custom: \(summarizer.ollamaModel)").tag(summarizer.ollamaModel)
                }
            }
            .pickerStyle(.menu)
            // Pull the real installed-model list from /api/tags on first
            // appearance and whenever the server URL changes. An empty
            // result (server unreachable) leaves ollamaModelChoices on
            // the static catalog.
            .task(id: summarizer.ollamaBaseURL) {
                ollamaInstalledModels = await OllamaAPISummarizer.fetchInstalledModels(
                    baseURL: URL(string: summarizer.ollamaBaseURL)
                        ?? URL(string: OllamaAPISummarizer.defaultBaseURLString)!
                )
            }
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
            if OllamaAPISummarizer.isCloudModel(summarizer.ollamaModel) {
                return "“\(summarizer.ollamaModel)” is an Ollama cloud model: your local Ollama daemon proxies the request to ollama.com, so the transcript LEAVES your Mac (Ollama bills the usage). For fully on-device summaries pick a model without a `:cloud`/`-cloud` tag."
            }
            return "Daisy calls your local Ollama server (`ollama serve`) over its native `/api/chat` REST. No API key, no network egress — everything stays on your Mac. Pull the model first: `ollama pull \(OllamaAPISummarizer.defaultModelID)`. Free."
        case .lmStudio:
            return "Daisy calls your local LM Studio server over its OpenAI-compatible `/v1/chat/completions` REST. No API key, no network egress — everything stays on your Mac. Load a model in the LM Studio app and click Developer → Start. The API identifier in this picker must match the one LM Studio shows under the loaded model. Free."
        case .mcp:
            return "Advanced — for users running a custom MCP server (Python shim, `mcp-ollama` wrapper, etc.). Daisy connects over HTTP+SSE and calls one tool per summary. For stock Ollama or LM Studio use their dedicated providers above instead — those work without an MCP shim."
        }
    }

    /// Model picker choices for Ollama. Prefers the live `/api/tags`
    /// listing (what the user has actually pulled, including spooled
    /// `:cloud` stubs); falls back to the static catalog when the
    /// server is unreachable. Known ids reuse the catalog's friendly
    /// label; unknown ids show the raw tag, and cloud models are marked
    /// so the egress is visible before selection.
    private var ollamaModelChoices: [(id: String, label: String)] {
        guard !ollamaInstalledModels.isEmpty else {
            return OllamaAPISummarizer.availableModels
        }
        let catalog = Dictionary(
            OllamaAPISummarizer.availableModels.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        return ollamaInstalledModels.map { name in
            if let known = catalog[name] { return (id: name, label: known) }
            let suffix = OllamaAPISummarizer.isCloudModel(name) ? " — cloud (ollama.com)" : ""
            return (id: name, label: name + suffix)
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

/// Result of a "Test connection / Test summary" probe — drives the
/// inline StatusBadge next to the Test button. Hoisted to file scope
/// (1.0.7.16) from a nested `SettingsView.TestResult` when the Notion
/// destination config moved to ConnectionsView: SettingsView's Summary
/// test (`summaryTestResult`) and ConnectionsView's Notion test
/// (`notionTestResult`) both reference it now, and a private nested
/// enum wouldn't be visible across the two files. Single definition —
/// do not duplicate.
enum TestResult: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

#Preview {
    SettingsView(settings: AppSettings())
}
