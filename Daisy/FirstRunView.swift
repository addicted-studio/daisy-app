//
//  FirstRunView.swift
//  Daisy
//
//  Multi-step welcome flow shown on first launch. Replaces the
//  earlier single-screen sheet — PM review (and the user) flagged
//  that one wall of info plus four CTAs is too much for the first
//  90 seconds. Now the user moves through 4 focused steps:
//
//      1. Welcome           — what Daisy does, one sentence
//      2. Microphone        — grant the permission inline
//      3. Screen recording  — grant the permission inline
//      4. You're set        — pointer to menu bar, optional CTAs
//                              into Settings (Summary, Integrations)
//
//  Each step owns one decision. Permission prompts fire inline so
//  the user doesn't have to "leave" Daisy to System Settings unless
//  they explicitly choose to. Permissions can be skipped — they're
//  re-requested at first recording with a clear toast (per the
//  ScreenRecordingPermission preflight path).
//

import SwiftUI
import AVFoundation
import CoreGraphics

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
        case done

        var progressIndex: Int { rawValue }
        static var total: Int { allCases.count }
    }

    @State private var step: Step = .welcome
    /// Permission states refreshed on .appear of each step — system
    /// can flip them out-of-band (user toggles in Settings while
    /// onboarding is open), and the cached value would otherwise lie.
    @State private var micGranted: Bool = false
    @State private var screenGranted: Bool = false

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
    }

    // MARK: - Progress dots
    //
    // Four small dots that fill as the user advances. Visual anchor
    // ("am I almost done?") without taking real estate from the
    // step content.

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue
                          ? Color.daisyAccent
                          : Color.daisyDivider)
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
            Text("Two short permission asks coming up, then you're set.")
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
                    detail: "Auto-send finished sessions to Notion right after Stop. (Power users: Connections → Auto-routing for Linear, Attio, webhooks, custom MCP wrappers.)",
                    action: {
                        // 1.0.5: Notion is the primary destination flow and now
                        // lives in Settings → General → Storage right under the
                        // sessions-folder picker. Landing here drops the user
                        // directly into the right Storage block.
                        nav.openInSettings(.general)
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
                    if let prev = Step(rawValue: step.rawValue - 1) {
                        step = prev
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
            case .microphone, .screenRecording:
                Button("Skip for now") { advance() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(Color.daisyTextPrimary)
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
    /// `CGRequestScreenCaptureAccess` triggers the system prompt
    /// and returns the resulting state. On macOS 14+ approval
    /// requires the user to open System Settings → Privacy & Security
    /// in a separate step (Apple's choice, not ours).
    private func requestScreenAccess() {
        let granted = CGRequestScreenCaptureAccess()
        screenGranted = granted
        if granted {
            advance()
        }
        // If still false after prompt, the user has to flip the
        // toggle in System Settings. Daisy's first recording will
        // re-prompt via the preflight path — onboarding just plants
        // the seed.
    }

    private func refreshPermissionStates() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: - Flow

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
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
