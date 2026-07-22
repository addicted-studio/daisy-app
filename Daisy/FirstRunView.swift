//
//  FirstRunView.swift
//  Daisy
//
//  Multi-step welcome flow shown on first launch.
//
//  Step flow (6 steps):
//      1. Welcome           — what Daisy does, one sentence
//      2. Microphone        — required permission (no recording w/o)
//      3. Screen Recording  — required for capturing the other side
//                              of meetings via system audio loopback
//      4. Accessibility     — required for the dictation hotkey's
//                              ⌘V auto-paste into the active app
//      5. Hotkeys           — assign global shortcuts for all three
//                              recording modes (meeting / voice notes
//                              / dictation) on a single screen
//      6. You're set        — pointer to menu bar, optional CTAs
//                              into Settings (Summary, Integrations)
//
//  Each permission step owns one decision and surfaces a single
//  primary action. Permission prompts fire inline; when the system
//  doesn't actually show the dialog (a known macOS 14+ bug for
//  Screen Recording — see ScreenRecordingPermission.swift), we fall
//  back to opening System Settings directly so the user is never
//  stuck on a dead button.
//
//  Permissions can be skipped (footer "Skip for now"); they re-prompt
//  at first use via the preflight path in each feature.
//

import SwiftUI
import AVFoundation
import CoreGraphics
import ApplicationServices

struct FirstRunView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AppSettings
    @Bindable var nav = AppNavigation.shared

    /// Steps the user walks through, in order. Raw values double as
    /// progress-dot indices.
    enum Step: Int, CaseIterable {
        case welcome
        case language
        case purpose
        case name
        case microphone
        case screenRecording
        case accessibility
        case hotkeys
        case done

        var progressIndex: Int { rawValue }
        static var total: Int { allCases.count }
    }

    /// Which setup track the user picked on the `purpose` step. Tailors
    /// what onboarding asks — the full track sets up meetings, dictation-
    /// only skips to the dictation essentials. NOT an app mode: the app
    /// stays whole; the user can enable the rest later (lazily).
    enum SetupPath { case full, dictationOnly }
    @State private var setupPath: SetupPath = .full

    /// Steps shown, branched by `setupPath`. Full asks the recording
    /// permission set (mic + screen + accessibility — full users dictate
    /// too) and all three hotkeys; dictation-only asks mic + accessibility
    /// and just the dictation hotkey. (Soft steps — folder, calendar,
    /// summary model, style/vocab import — land in a later pass.)
    private var orderedSteps: [Step] {
        switch setupPath {
        case .full:
            return [.welcome, .language, .purpose, .name,
                    .microphone, .screenRecording, .accessibility,
                    .hotkeys, .done]
        case .dictationOnly:
            return [.welcome, .language, .purpose,
                    .microphone, .accessibility, .hotkeys, .done]
        }
    }

    @State private var step: Step = .welcome
    /// Interface-language pick for the language step, seeded from the
    /// region heuristic below.
    @State private var uiLanguage: String = FirstRunView.recommendedLanguage()
    /// Permission states refreshed on .appear of each step + on app
    /// foreground-activation — system can flip them out-of-band (user
    /// toggles in Settings while onboarding is open), and the cached
    /// value would otherwise lie.
    @State private var micGranted: Bool = false
    @State private var screenGranted: Bool = false
    @State private var accessibilityGranted: Bool = false

    /// Default UI language for the language step: Russian for Russia &
    /// Belarus (or a ru/be system language); English for Ukraine — we
    /// never default Russian there — and for everyone else.
    static func recommendedLanguage() -> String {
        let region = Locale.current.region?.identifier
        let lang = Locale.current.language.languageCode?.identifier
        if region == "UA" || lang == "uk" { return "en" }
        if region == "RU" || region == "BY" || lang == "ru" || lang == "be" { return "ru" }
        return "en"
    }

    /// Persist the interface-language override — same keys as Settings →
    /// Language. Full effect on next launch (standard AppKit behaviour).
    private func applyLanguage(_ code: String) {
        let d = UserDefaults.standard
        d.set([code], forKey: "AppleLanguages")
        d.set(true, forKey: "AppleLanguagesOverridden")
    }

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 24)
                .padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .background(Color.daisyBgPrimary)
        .onAppear {
            refreshPermissionStates()
        }
        .onChange(of: step) { _, _ in
            refreshPermissionStates()
        }
        // Permissions can flip out-of-band while onboarding is open —
        // the user opens System Settings, grants Screen Recording,
        // returns to Daisy. Without a focus observer the onboarding
        // step is frozen on "Allow Screen Recording" until they
        // click Next, which feels like the app missed the grant.
        // Refresh on every foreground-activation keeps the UI honest.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshPermissionStates()
        }
    }

    // MARK: - Progress dots
    //
    // Four small dots that fill as the user advances. Visual anchor
    // ("am I almost done?") without taking real estate from the
    // step content.

    private var progressDots: some View {
        let steps = orderedSteps
        let current = steps.firstIndex(of: step) ?? 0
        return HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, _ in
                Circle()
                    .fill(idx <= current ? Color.daisyAccent : Color.daisyDivider)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        Group {
            switch step {
            case .welcome: welcomeStep
            case .language: languageStep
            case .purpose: purposeStep
            case .name: nameStep
            case .microphone: micStep
            case .screenRecording: screenStep
            case .accessibility: accessibilityStep
            case .hotkeys: hotkeysStep
            case .done: doneStep
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                DaisyMark(size: 40, tint: .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Daisy")
                        .font(.title2.weight(.semibold))
                    Text("Local meeting capture for Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer().frame(height: 8)
            Text("Daisy records the audio of your meetings, writes the transcript on your Mac, and lets you send the result wherever you want — Notion, Linear, Claude, your own webhook.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A few quick questions and permissions, then you're set.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Language")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("Choose the language for Daisy's interface. You can change it later in Settings.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $uiLanguage) {
                Text("English").tag("en")
                Text(verbatim: "Русский").tag("ru")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            .onChange(of: uiLanguage) { _, new in applyLanguage(new) }
            Spacer()
        }
    }

    private var purposeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("What do you need Daisy for?")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("We'll set up only what you need — you can enable the rest anytime.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            purposeOption(
                title: String(localized: "Meetings + dictation"),
                detail: String(localized: "Record and transcribe meetings, and dictate into any app."),
                path: .full
            )
            purposeOption(
                title: String(localized: "Just dictation"),
                detail: String(localized: "Talk, and Daisy types it into whatever app you're in."),
                path: .dictationOnly
            )
            Spacer()
        }
    }

    /// One selectable card on the purpose step — picking it sets the track
    /// and advances immediately (no separate Continue).
    private func purposeOption(title: String, detail: String, path: SetupPath) -> some View {
        Button {
            setupPath = path
            advance()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.daisyTextPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("What should we call you?")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("Used to greet you and to label your voice in transcripts. Optional — leave it blank to skip.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Your name"), text: $settings.userDisplayName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
        }
    }

    private var micStep: some View {
        StepView(
            icon: "mic.fill",
            title: String(localized: "Microphone"),
            description: String(localized: "Daisy needs to hear your voice. Audio is recorded locally and transcribed on-device — nothing about it leaves your Mac."),
            statusGranted: micGranted,
            primaryActionLabel: micGranted ? String(localized: "Continue") : String(localized: "Allow microphone"),
            onPrimary: {
                if micGranted {
                    advance()
                } else {
                    Task { await requestMicAccess() }
                }
            }
        )
    }

    private var screenStep: some View {
        StepView(
            icon: "rectangle.dashed.badge.record",
            title: String(localized: "Screen Recording"),
            description: String(localized: "Lets Daisy hear the other side of meetings (Zoom, Meet, Teams) through the system audio loopback. Daisy never reads pixels or saves screenshots without your permission."),
            statusGranted: screenGranted,
            primaryActionLabel: screenGranted ? String(localized: "Continue") : String(localized: "Allow Screen Recording"),
            onPrimary: {
                if screenGranted {
                    advance()
                } else {
                    requestScreenAccess()
                }
            }
        )
    }

    private var accessibilityStep: some View {
        StepView(
            icon: "keyboard",
            title: String(localized: "Accessibility"),
            description: String(localized: "Required for the dictation hotkey — Daisy pastes the transcribed text into the active app via ⌘V. Without this, dictation falls back to copy-only (you have to paste yourself)."),
            statusGranted: accessibilityGranted,
            primaryActionLabel: accessibilityGranted ? String(localized: "Continue") : String(localized: "Allow Accessibility"),
            onPrimary: {
                if accessibilityGranted {
                    advance()
                } else {
                    requestAccessibilityAccess()
                }
            }
        )
    }

    private var hotkeysStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "keyboard.fill")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Hotkeys")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text(setupPath == .full
                 ? String(localized: "Pick a global shortcut for each recording mode. You can change them later in Settings → Recording → Shortcuts.")
                 : String(localized: "Pick a global shortcut for dictation. You can change it later in Settings → Recording → Shortcuts."))
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                if setupPath == .full {
                    hotkeyRow(
                        title: String(localized: "Meeting"),
                        description: String(localized: "Captures mic + system audio together."),
                        color: .daisyRecording,
                        binding: $settings.recordHotkey
                    )
                    hotkeyRow(
                        title: String(localized: "Voice notes"),
                        description: String(localized: "Quick one-off thought, mic only."),
                        color: .daisyVoiceNote,
                        binding: $settings.voiceNoteHotkey
                    )
                }
                hotkeyRow(
                    title: String(localized: "Dictation"),
                    description: String(localized: "Hold to talk, release to paste at cursor."),
                    color: .daisyDictation,
                    binding: $settings.dictationHotkey
                )
            }
            Spacer()
        }
    }

    /// Single row in the hotkeys step — colour dot matching the
    /// widget centre for that mode + name + description + the shared
    /// `HotkeyRecorder` button (so the recording UX is identical to
    /// Settings → Hotkeys; users learn it once).
    @ViewBuilder
    private func hotkeyRow(
        title: String,
        description: String,
        color: Color,
        binding: Binding<HotkeyChoice>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HotkeyRecorder(value: binding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    /// Short human label for the current Whisper load state. Nil when
    /// the model is ready (we hide the row entirely in that case so the
    /// Done step doesn't show stale "100%" after the load completes).
    private var whisperProgressLine: String? {
        switch WhisperEngine.shared.state {
        case .notLoaded:
            return String(localized: "Setting up transcription model…")
        case .downloading(let p):
            return String(localized: "Downloading transcription model · \(Int(p * 100))%")
        case .loading(let status):
            return String(localized: "Loading transcription model · \(status)")
        case .ready, .failed:
            return nil
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.daisySuccess)
                Text("You're set")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("Start a recording from the menu bar (the daisy icon at the top of your screen) or press your global shortcut.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Inline progress row — only visible if WhisperEngine is
            // still downloading or loading the model. Prewarm kicked
            // off from `RecordingSession.init()` runs while the user
            // walks the onboarding; on a fresh install this row is
            // visible for the full Done step. SwiftUI re-renders on
            // every `WhisperEngine.shared.state` change because @Observable
            // tracks the access from within the view body.
            if let line = whisperProgressLine {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Optional setup")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                ctaRow(
                    title: String(localized: "Pick an AI for summaries"),
                    detail: String(localized: "Apple Intelligence runs offline on macOS 26; otherwise paste an Anthropic or OpenAI key."),
                    action: {
                        nav.openInSettings(.summary)
                        finish()
                    }
                )
                ctaRow(
                    title: String(localized: "Wire a destination"),
                    detail: String(localized: "Auto-send finished recordings to Notion right after Stop — plus Linear, Attio, webhooks, and custom MCP wrappers."),
                    action: {
                        // 1.0.7.16: Notion moved out of Settings onto the
                        // top-level Connections page → Auto-routing tab,
                        // alongside the other send-to destinations. Land the
                        // user there so the Notion row and the MCP
                        // integrations are in one place.
                        nav.openInConnections(.autoRouting)
                        finish()
                    }
                )
            }
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Back button — visible after step 0 so the user can
            // revisit a permission they tapped Skip on without
            // restarting the whole flow.
            if step.rawValue > 0, step != .done {
                Button("Back") {
                    let steps = orderedSteps
                    if let i = steps.firstIndex(of: step), i > 0 {
                        step = steps[i - 1]
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(Color.daisyTextPrimary)
            }
            Spacer()
            // Step-specific footer right side:
            //   • Welcome → primary "Get started" advances
            //   • Permission steps → tertiary "Skip for now"
            //   • Done → primary "Start using Daisy"
            switch step {
            case .welcome:
                Button("Get started") { advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
                    // Ink-on-accent: the system's white label fails
                    // WCAG on the amber fill (≈2:1 in dark).
                    .foregroundStyle(Color.daisyTextOnAccent)
                    .keyboardShortcut(.defaultAction)
            case .language:
                Button("Continue") { applyLanguage(uiLanguage); advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
                    .foregroundStyle(Color.daisyTextOnAccent)
                    .keyboardShortcut(.defaultAction)
            case .purpose:
                // The two option cards advance on tap — no footer action.
                EmptyView()
            case .name:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
                    .foregroundStyle(Color.daisyTextOnAccent)
                    .keyboardShortcut(.defaultAction)
            case .microphone, .screenRecording, .accessibility:
                Button("Skip for now") { advance() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(Color.daisyTextPrimary)
            case .hotkeys:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
                    .foregroundStyle(Color.daisyTextOnAccent)
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Start using Daisy") { finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
                    .foregroundStyle(Color.daisyTextOnAccent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Optional CTAs (on Done step)

    @ViewBuilder
    private func ctaRow(title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.daisyTextPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission requests

    /// Modern API for mic — `AVCaptureDevice.requestAccess(for:)` is
    /// async-friendly and triggers the system prompt only when the
    /// status is undetermined. Already-granted returns true without
    /// re-prompting; denied returns false without prompting again.
    private func requestMicAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micGranted = granted
        if granted {
            advance()
        }
    }

    /// Screen Recording uses the lower-level CoreGraphics API.
    ///
    /// `CGRequestScreenCaptureAccess` is documented to show the
    /// system dialog. In practice on macOS 14+ it is **unreliable**:
    /// returns `false` without showing any prompt for most users.
    /// Without a fallback, the onboarding button is a dead end —
    /// click, nothing happens, click again, same.
    ///
    /// Two-pronged fix matching `SystemPermissions.requestScreenRecording()`:
    ///   1. Call CGRequestScreenCaptureAccess — if the prompt does
    ///      fire and the user grants, we advance immediately.
    ///   2. If the call returned false (either prompt didn't fire,
    ///      or user denied), open System Settings → Privacy → Screen
    ///      Recording directly so the user has a path forward. The
    ///      focus observer on the parent view refreshes status when
    ///      they come back, and the "Granted" badge appears without
    ///      needing another click.
    private func requestScreenAccess() {
        let granted = CGRequestScreenCaptureAccess()
        screenGranted = granted
        if granted {
            advance()
        } else {
            // Open System Settings as fallback — the user grants
            // there, then we auto-detect on return-to-foreground.
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    /// Accessibility permission is requested via the canonical
    /// `AXIsProcessTrustedWithOptions(prompt: true)` API. macOS shows
    /// a system sheet pointing the user at System Settings → Privacy
    /// → Accessibility; there's no auto-grant from here. The focus
    /// observer on the parent view re-checks on return and the
    /// "Granted" badge appears without needing another click.
    private func requestAccessibilityAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // No advance — flip happens out-of-band when the user returns
        // from System Settings, caught by the focus observer.
    }

    private func refreshPermissionStates() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    // MARK: - Flow

    private func advance() {
        let steps = orderedSteps
        if let i = steps.firstIndex(of: step), i + 1 < steps.count {
            step = steps[i + 1]
        } else {
            finish()
        }
    }

    private func finish() {
        settings.hasShownFirstRun = true
        dismiss()
    }
}

// MARK: - Permission step layout
//
// Shared between mic + screen-recording steps. Centralises the
// icon + title + body + grant button + status badge layout so the
// two steps stay visually identical and we only describe the
// "what / why" string per step.

private struct StepView: View {
    let icon: String
    let title: String
    /// The explanatory paragraph under the title. Named `description`
    /// rather than `body` because the latter collides with
    /// `View.body`'s required property name and Swift flags it as
    /// invalid redeclaration.
    let description: String
    let statusGranted: Bool
    let primaryActionLabel: String
    let onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                if statusGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.daisySuccess)
                }
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(primaryActionLabel, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .tint(Color.daisyAccent)
                .foregroundStyle(Color.daisyTextOnAccent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview {
    FirstRunView(settings: AppSettings())
}
