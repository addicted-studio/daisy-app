//
//  FirstRunView.swift
//  Daisy
//
//  Multi-step welcome flow shown on first launch. Fills the whole main
//  window (no sidebar) — see MainView's first-run branch.
//
//  Layout: two columns when the window is wide enough — a step rail on
//  the left (done / current / upcoming, done steps clickable) and the
//  current step's content in a readable column on the right. Below
//  ~760pt the rail doesn't fit and we fall back to a single column with
//  progress dots on top.
//
//  Step order lives in `steps(for:installedLayoutCount:)` — a pure
//  function so the order is unit-tested. Welcome, language, purpose,
//  name, then the permission block (mic / screen / accessibility),
//  hotkeys, the layout-fixer step (only with 2+ installed keyboard
//  layouts), calendar, summaries, done.
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
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices
import EventKit
import FoundationModels

struct FirstRunView: View {
    @Bindable var settings: AppSettings
    @Bindable var nav = AppNavigation.shared

    /// Steps the user walks through, in order.
    enum Step: Int, CaseIterable {
        case welcome
        case language
        case purpose
        case name
        case microphone
        case screenRecording
        case accessibility
        case hotkeys
        /// The wrong-layout fixer — asked only of people with 2+
        /// installed keyboard layouts (see `steps(for:installedLayoutCount:)`).
        case layout
        // Soft, optional setup steps. Each is skippable via its
        // "Continue" footer — no action is forced.
        case calendar
        case model
        case done

        /// Short name shown in the step rail / used by both columns.
        var railTitle: String {
            switch self {
            case .welcome:         String(localized: "Welcome")
            case .language:        String(localized: "Language")
            case .purpose:         String(localized: "Purpose")
            case .name:            String(localized: "Your name")
            case .microphone:      String(localized: "Microphone")
            case .screenRecording: String(localized: "Screen Recording")
            case .accessibility:   String(localized: "Accessibility")
            case .hotkeys:         String(localized: "Hotkeys")
            case .layout:          String(localized: "Keyboard layout")
            case .calendar:        String(localized: "Calendar")
            case .model:           String(localized: "Summaries")
            case .done:            String(localized: "You're set")
            }
        }
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
    /// and just the dictation hotkey. After the permission/hotkey block
    /// come the optional "soft" steps: full gets calendar + summary
    /// model; dictation-only skips them (both are meeting-oriented).
    private var orderedSteps: [Step] {
        Self.steps(for: setupPath,
                   installedLayoutCount: KeyboardLayouts.shared.installed.count)
    }

    /// Pure step-order builder, extracted so the order is unit-testable
    /// (see FirstRunStepsTests). The layout-fixer step exists only for
    /// people with 2+ installed keyboard layouts — with one layout there
    /// is nothing to switch between and the question is noise.
    static func steps(for path: SetupPath, installedLayoutCount: Int) -> [Step] {
        let layoutFixer: [Step] = installedLayoutCount > 1 ? [.layout] : []
        switch path {
        case .full:
            return [.welcome, .language, .purpose, .name,
                    .microphone, .screenRecording, .accessibility,
                    .hotkeys] + layoutFixer + [.calendar, .model, .done]
        case .dictationOnly:
            return [.welcome, .language, .purpose,
                    .microphone, .accessibility, .hotkeys]
                    + layoutFixer + [.done]
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

    // ─── Soft-step state ──────────────────────────────────────────────
    /// Summary provider is @Observable but lives outside `settings`, so
    /// it needs its own @Bindable to drive the provider Picker.
    @Bindable private var summarizer = Summarizer.shared
    /// One-shot guard for seeding Apple Intelligence as the SELECTED
    /// provider on the model step. Seeded once so a user who picks a
    /// cloud provider, goes back and returns isn't overridden.
    @State private var modelStepSeeded: Bool = false

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

    /// Below this window width the rail + readable column don't both
    /// fit; fall back to a single column with progress dots on top.
    private static let twoColumnThreshold: CGFloat = 760
    private static let railWidth: CGFloat = 240
    /// Cap on the content column so a wide monitor doesn't stretch
    /// every line of copy across the whole window.
    private static let contentMaxWidth: CGFloat = 560

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.twoColumnThreshold {
                twoColumnLayout
            } else {
                singleColumnLayout
            }
        }
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

    // MARK: - Column layouts

    /// Wide window: step rail on the left, the current step's content in
    /// a readable centered column on the right, Back/Next pinned to the
    /// bottom of the right column.
    private var twoColumnLayout: some View {
        HStack(spacing: 0) {
            stepRail
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.daisyBgSidebar)
            Divider()
                .overlay(Color.daisyDivider)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
                    .frame(maxWidth: Self.contentMaxWidth)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Narrow window (below `twoColumnThreshold`): the pre-rail layout —
    /// progress dots on top, content, footer. The user can shrink the
    /// window mid-onboarding, so this is a live fallback, not a relic.
    private var singleColumnLayout: some View {
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
    }

    // MARK: - Step rail

    /// Left rail listing every step of the current path top to bottom.
    /// Three states — done (clickable, returns to that step), current,
    /// upcoming (inert: no jumping ahead past a permission ask).
    private var stepRail: some View {
        let steps = orderedSteps
        let current = steps.firstIndex(of: step) ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text("Setup")
                .daisyStatLabel()
                .padding(.leading, 10)
                .padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.element) { index, s in
                railRow(
                    s,
                    state: index < current ? .done
                         : index == current ? .current : .upcoming
                ) {
                    step = s
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // The window keeps `.fullSizeContentView` + a transparent
        // titlebar (DaisyAppDelegate), so the rail extends under the
        // traffic lights — leave them headroom.
        .padding(.top, 52)
        .padding(.bottom, 16)
    }

    private enum RailStepState { case done, current, upcoming }

    private func railRow(
        _ s: Step,
        state: RailStepState,
        activate: @escaping () -> Void
    ) -> some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                Group {
                    switch state {
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.daisyAccent)
                    case .current:
                        Image(systemName: "circle.inset.filled")
                            .foregroundStyle(Color.daisyAccent)
                    case .upcoming:
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .frame(width: 16)
                Text(s.railTitle)
                    .font(.callout.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(
                        state == .upcoming ? AnyShapeStyle(.tertiary)
                                           : AnyShapeStyle(Color.daisyTextPrimary)
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                state == .current ? AnyShapeStyle(Color.daisySidebarSelection)
                                  : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // Only already-visited steps are navigable; the current row and
        // future rows don't react.
        .disabled(state != .done)
    }

    // MARK: - Progress dots (single-column fallback)
    //
    // Small dots that fill as the user advances. Visual anchor
    // ("am I almost done?") without taking real estate from the
    // step content. In the wide layout the rail replaces these.

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
            case .layout: layoutStep
            case .calendar: calendarStep
            case .model: modelStep
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

    // MARK: - Soft steps

    /// The wrong-layout fixer — shown only when 2+ keyboard layouts are
    /// installed. One phrase about what it does, the as-you-type toggle
    /// and the fix key, in the same card-row shell as `hotkeyRow` so the
    /// key-recording UX is learned once. The `.accessibility` step comes
    /// earlier; if the grant was skipped, say so here instead of
    /// offering a toggle that silently does nothing. Flipping the toggle
    /// really starts the tap: MainView's `HotkeyStopWiring` observes
    /// `settings.layoutFixAuto` from OUTSIDE the first-run branch, so
    /// the re-wiring fires during onboarding too.
    private var layoutStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Keyboard layout")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("Daisy notices a word typed in the wrong keyboard layout and fixes it — before you send the message.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !accessibilityGranted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.daisyAccent)
                    Text("Accessibility access isn't granted yet, so Daisy can't rewrite what you type — nothing below will work until it is.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Allow Accessibility") {
                        requestAccessibilityAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color.daisyAccent.opacity(0.20),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
                )
            }

            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Fix the layout as I type")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Toggle("", isOn: $settings.layoutFixAuto)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                )
                hotkeyRow(
                    title: String(localized: "Fix the keyboard layout"),
                    description: String(localized: "«ghbdtn» becomes «привет» — the selection, or the word you're typing"),
                    color: .daisyAccent,
                    binding: $settings.layoutFixHotkey
                )
            }
            Spacer()
        }
    }

    /// Calendar — connect via EventKit, then pick an auto-record policy.
    /// Reading `CalendarService.shared.authorizationStatus` (an
    /// @Observable property) inside the body means the "Connected" state
    /// flips live when the grant lands, without an extra observer here.
    private var calendarStep: some View {
        let connected = CalendarService.shared.authorizationStatus == .fullAccess
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Calendar")
                    .font(.title2.weight(.semibold))
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.daisySuccess)
                }
            }
            Text("Connect your calendar so Daisy can start recording automatically when a meeting begins. You can change this anytime in Settings.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if connected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-record")
                        .font(.callout.weight(.medium))
                    Picker("", selection: $settings.autoStartPolicy) {
                        ForEach(AutoStartPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                )
            } else {
                Button("Connect calendar") {
                    Task { await CalendarService.shared.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.daisyAccent)
                .foregroundStyle(Color.daisyTextOnAccent)
                .controlSize(.regular)
            }
            Spacer()
        }
    }

    /// Summaries — provider Picker + inline key. Offers only a small
    /// onboarding subset (Apple Intelligence when available + the two
    /// key-based cloud providers); local/self-hosted options are set up
    /// later in Settings.
    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Summaries")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("Choose the AI that writes your meeting summaries. You can change it or add other providers later in Settings.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $summarizer.providerKind) {
                    ForEach(onboardingProviders, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)

                switch summarizer.providerKind {
                case .anthropic:
                    SecureField(String(localized: "Anthropic API key"),
                                text: $settings.anthropicAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                case .openai:
                    SecureField(String(localized: "OpenAI API key"),
                                text: $settings.openaiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                case .kimi:
                    SecureField(String(localized: "Kimi API key"),
                                text: $settings.kimiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                case .appleIntelligence:
                    Text("Runs on-device — no API key needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }

                // Continue works without a key — say so, so an empty
                // field doesn't read as a wall. Whoever wants to look
                // around first pastes the key later.
                if summarizer.providerKind.requiresAPIKey {
                    Text("No key yet? Continue — you can add it later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
            Spacer()
        }
        // Apple Intelligence must be SELECTED when it can run, not
        // merely listed first. One-shot: coming back to this step after
        // picking a cloud provider doesn't override the choice.
        .onAppear {
            guard !modelStepSeeded else { return }
            modelStepSeeded = true
            if appleIntelligenceAvailable {
                summarizer.providerKind = .appleIntelligence
            }
        }
    }

    /// Whether Apple Intelligence's on-device model is actually usable —
    /// the same availability gate `AppleIntelligenceSummarizer.isReady()`
    /// applies, so onboarding never offers a provider that can't run.
    private var appleIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default: return false
            }
        }
        return false
    }

    /// Providers offered during onboarding — a deliberately small subset.
    /// Order: Apple Intelligence (when it can run), Anthropic, OpenAI,
    /// Kimi. The current selection is always included so the menu Picker
    /// never renders a blank tag if the persisted provider is one we
    /// don't list.
    private var onboardingProviders: [SummaryProviderKind] {
        var list: [SummaryProviderKind] = []
        if appleIntelligenceAvailable { list.append(.appleIntelligence) }
        list.append(.anthropic)
        list.append(.openai)
        list.append(.kimi)
        if !list.contains(summarizer.providerKind) {
            list.append(summarizer.providerKind)
        }
        return list
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
            case .layout, .calendar, .model:
                // Soft steps: their controls act inline; the footer just
                // advances. Nothing is forced — Continue is always valid.
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

    /// End of the flow. Setting `hasShownFirstRun` is the whole
    /// contract: MainView branches on it, so the window swaps back to
    /// the ordinary split shell the moment it flips.
    private func finish() {
        settings.hasShownFirstRun = true
        // Changing AppleLanguages does not refresh Bundle.main in the
        // running process. Relaunch when onboarding selected a different
        // interface language, so the rest of the app does not stay English.
        let activeLanguage = Bundle.main.preferredLocalizations.first?
            .prefix(2)
            .lowercased()
        if activeLanguage != uiLanguage {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration,
            ) { _, _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        }
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
