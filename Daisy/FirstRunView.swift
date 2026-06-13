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
        case microphone
        case screenRecording
        case accessibility
        case hotkeys
        case done

        var progressIndex: Int { rawValue }
        static var total: Int { allCases.count }
    }

    /// The steps actually shown, in order. Onboarding asks only for the
    /// minimal dictation permission set — Microphone + Accessibility.
    /// Screen Recording is no longer asked at onboarding; it's requested
    /// lazily on the first meeting recording (its `.screenRecording` step
    /// stays defined but is intentionally absent from this list).
    private var orderedSteps: [Step] {
        [.welcome, .microphone, .accessibility, .hotkeys, .done]
    }

    @State private var step: Step = .welcome
    /// Permission states refreshed on .appear of each step + on app
    /// foreground-activation — system can flip them out-of-band (user
    /// toggles in Settings while onboarding is open), and the cached
    /// value would otherwise lie.
    @State private var micGranted: Bool = false
    @State private var screenGranted: Bool = false
    @State private var accessibilityGranted: Bool = false

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
            Text("A couple of quick permission asks and one hotkey screen, then you're set.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var micStep: some View {
        StepView(
            icon: "mic.fill",
            title: "Microphone",
            description: "Daisy needs to hear your voice. Audio is recorded locally and transcribed on-device — nothing about it leaves your Mac.",
            statusGranted: micGranted,
            primaryActionLabel: micGranted ? "Continue" : "Allow microphone",
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
            title: "Screen Recording",
            description: "Lets Daisy hear the other side of meetings (Zoom, Meet, Teams) through the system audio loopback. Daisy never reads pixels or saves screenshots without your permission.",
            statusGranted: screenGranted,
            primaryActionLabel: screenGranted ? "Continue" : "Allow Screen Recording",
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
            title: "Accessibility",
            description: "Required for the dictation hotkey — Daisy pastes the transcribed text into the active app via ⌘V. Without this, dictation falls back to copy-only (you have to paste yourself).",
            statusGranted: accessibilityGranted,
            primaryActionLabel: accessibilityGranted ? "Continue" : "Allow Accessibility",
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
            Text("Pick a global shortcut for each recording mode. You can change them later in Settings → Hotkeys.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                hotkeyRow(
                    title: "Meeting",
                    description: "Captures mic + system audio together.",
                    color: .daisyRecording,
                    binding: $settings.recordHotkey
                )
                hotkeyRow(
                    title: "Voice notes",
                    description: "Quick one-off thought, mic only.",
                    color: .daisyVoiceNote,
                    binding: $settings.voiceNoteHotkey
                )
                hotkeyRow(
                    title: "Dictation",
                    description: "Hold to talk, release to paste at cursor.",
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
            return "Setting up transcription model…"
        case .downloading(let p):
            return "Downloading transcription model · \(Int(p * 100))%"
        case .loading(let status):
            return "Loading transcription model · \(status)"
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
                    title: "Pick an AI for summaries",
                    detail: "Apple Intelligence runs offline on macOS 26; otherwise paste an Anthropic or OpenAI key.",
                    action: {
                        nav.openInSettings(.summary)
                        finish()
                    }
                )
                ctaRow(
                    title: "Wire a destination",
                    detail: "Auto-send finished recordings to Notion right after Stop — plus Linear, Attio, webhooks, and custom MCP wrappers.",
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
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Start using Daisy") { finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
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
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview {
    FirstRunView(settings: AppSettings())
}
