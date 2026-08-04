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
//  function so the order is unit-tested. Welcome, purpose, name, one
//  permissions screen (mic / screen / accessibility as rows, the set
//  depends on the setup path), hotkeys, the layout-fixer step (only
//  with 2+ installed keyboard layouts), calendar, summaries, done.
//
//  Permission state comes from SystemPermissions.shared — the same
//  tri-state façade Settings → Permissions uses — so each row can
//  honestly branch: not asked → Allow (fires the system prompt);
//  granted → checkmark; denied → Open Settings… (macOS asks once, a
//  second Allow would silently do nothing and read as a broken app).
//
//  There is no language step: macOS picks the interface language from
//  the user's preferred-languages list (plus the one-shot `be` → `ru`
//  fallback in AppSettings.applyBelarusianLanguageFallbackIfNeeded).
//  Settings → Language is where an explicit override lives.
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
import EventKit
import FoundationModels

struct FirstRunView: View {
    @Bindable var settings: AppSettings
    @Bindable var nav = AppNavigation.shared

    /// Steps the user walks through, in order.
    enum Step: Int, CaseIterable {
        case purpose
        case name
        /// One screen for the whole permission set — which rows it
        /// shows depends on `SetupPath` (see `permissionsStep`).
        case permissions
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
            case .purpose:         String(localized: "Purpose")
            case .name:            String(localized: "Your name")
            case .permissions:     String(localized: "Permissions")
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
            return [.purpose, .name, .permissions,
                    .hotkeys] + layoutFixer + [.calendar, .model, .done]
        case .dictationOnly:
            return [.purpose, .permissions, .hotkeys]
                    + layoutFixer + [.done]
        }
    }

    @State private var step: Step = .purpose
    /// Permission state lives in `SystemPermissions.shared` (@Observable,
    /// same façade Settings → Permissions reads), refreshed on step
    /// change + on app foreground-activation — the system can flip
    /// grants out-of-band (user toggles in System Settings while
    /// onboarding is open), and a cached value would otherwise lie.
    /// One refresh updates every row of the permissions step at once.
    private var perms: SystemPermissions { SystemPermissions.shared }
    /// Whether THIS onboarding session already fired the Accessibility
    /// prompt. macOS asks once — after that `AXIsProcessTrustedWithOptions`
    /// silently does nothing — and unlike mic there is no API that
    /// distinguishes "never asked" from "denied". Local tracking is
    /// enough here: on a fresh install nobody has been asked yet.
    @State private var accessibilityAsked: Bool = false

    // ─── Soft-step state ──────────────────────────────────────────────
    /// Summary provider is @Observable but lives outside `settings`, so
    /// it needs its own @Bindable to drive the provider Picker.
    @Bindable private var summarizer = Summarizer.shared
    /// One-shot guard for seeding Apple Intelligence as the SELECTED
    /// provider on the model step. Seeded once so a user who picks a
    /// cloud provider, goes back and returns isn't overridden.
    @State private var modelStepSeeded: Bool = false

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
            case .purpose: purposeStep
            case .name: nameStep
            case .permissions: permissionsStep
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

    /// First screen: welcome + the setup-path choice merged into one.
    /// A short pitch (what Daisy does, one sentence) instead of the old
    /// full paragraph — the two option cards below carry the actual
    /// meaning now, so the pitch just needs to orient, not sell.
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
            Text("Daisy records meetings and dictates into any app — all on your Mac.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// One screen for the whole permission set. Title, one sentence
    /// about asking exactly this much, then a row per permission —
    /// icon, name, one line of "why", and a control that matches the
    /// REAL state: Allow fires the system prompt only while the system
    /// would actually show one; once denied, the row offers Open
    /// Settings… instead, because a second Allow silently does nothing
    /// and reads as a broken app. Dictation-only setups skip the
    /// Screen Recording row — nothing meeting-shaped is asked of them.
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Permissions")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Text("Daisy asks for exactly what its features need — nothing more.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill",
                    title: String(localized: "Microphone"),
                    why: String(localized: "Your voice — recorded and transcribed on this Mac."),
                    status: perms.microphone,
                    allow: { Task { await SystemPermissions.shared.requestMicrophone() } },
                    openSettings: { SystemPermissions.shared.openMicrophoneSettings() }
                )
                if setupPath == .full {
                    permissionRow(
                        icon: "rectangle.dashed.badge.record",
                        title: String(localized: "Screen Recording"),
                        why: String(localized: "The other side of meetings, through system audio."),
                        status: perms.screenRecording,
                        // Falls back to opening System Settings itself
                        // when the macOS 14+ prompt doesn't fire — see
                        // SystemPermissions.requestScreenRecording.
                        allow: { SystemPermissions.shared.requestScreenRecording() },
                        openSettings: { SystemPermissions.shared.openScreenRecordingSettings() }
                    )
                }
                permissionRow(
                    icon: "keyboard",
                    title: String(localized: "Accessibility"),
                    why: String(localized: "Pastes dictated text into the app you're in."),
                    status: accessibilityRowStatus,
                    allow: {
                        accessibilityAsked = true
                        SystemPermissions.shared.requestAccessibility()
                    },
                    openSettings: { SystemPermissions.shared.openAccessibilitySettings() }
                )
            }

            // The microphone is the one permission Daisy cannot work
            // without. Continue stays enabled — nothing is forced —
            // but the consequence is said out loud, not implied.
            if perms.microphone != .granted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.daisyAccent)
                    Text("Without the microphone Daisy can't record anything — the rest can wait.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
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
            Spacer()
        }
    }

    /// Accessibility's row status. `AXIsProcessTrusted` is a Bool, so
    /// SystemPermissions can never report `.denied` for it — the local
    /// `accessibilityAsked` flag supplies the third state: once this
    /// session has fired the one-shot prompt and the grant still isn't
    /// there, the only honest control is Open Settings….
    private var accessibilityRowStatus: SystemPermissions.Status {
        if perms.accessibility == .granted { return .granted }
        return accessibilityAsked ? .denied : .notDetermined
    }

    /// Single permission row: icon + name + one-line why on the left,
    /// the state-matched control on the right. Same card shell as
    /// `hotkeyRow` so the whole flow reads as one family.
    private func permissionRow(
        icon: String,
        title: String,
        why: String,
        status: SystemPermissions.Status,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(status == .granted ? Color.daisySuccess : Color.daisyAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.daisySuccess)
            case .notDetermined:
                Button("Allow") { allow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.daisyAccent)
                    .foregroundStyle(Color.daisyTextOnAccent)
            case .denied, .restricted, .insufficient:
                Button("Open Settings…") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
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

            if perms.accessibility != .granted {
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
                        accessibilityAsked = true
                        SystemPermissions.shared.requestAccessibility()
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
                .buttonStyle(DaisyStepButtonStyle(filled: false))
            }
            Spacer()
            // Step-specific footer right side:
            //   • Purpose → the two option cards advance on tap, no button
            //   • Everything else → "Continue" (or "Start using Daisy" on
            //     the last step) — inline row controls (permissions,
            //     hotkeys, the layout toggle) do their own thing; nothing
            //     here is ever forced.
            switch step {
            case .purpose:
                EmptyView()
            case .name, .permissions, .hotkeys, .layout, .calendar, .model:
                Button("Continue") { advance() }
                    .buttonStyle(DaisyStepButtonStyle(filled: true))
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Start using Daisy") { finish() }
                    .buttonStyle(DaisyStepButtonStyle(filled: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// Onboarding's Back/Continue actions, sharing RecordCapsule's
    /// geometry (see `DaisyCapsuleMetrics`) so the "next" action carries
    /// the same visual weight as the app's other primary action. No new
    /// colors — `filled` picks between the existing accent capsule
    /// (Continue) and the same shape with no fill (Back), both already
    /// used elsewhere in the app.
    private struct DaisyStepButtonStyle: ButtonStyle {
        var filled: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(DaisyCapsuleMetrics.font)
                .padding(.horizontal, DaisyCapsuleMetrics.horizontalPadding)
                .padding(.vertical, DaisyCapsuleMetrics.verticalPadding)
                // Ink-on-accent: the system's white label fails WCAG on
                // the amber fill (≈2:1 in dark).
                .foregroundStyle(filled ? Color.daisyTextOnAccent : Color.daisyTextPrimary)
                .background(
                    Capsule(style: .continuous)
                        .fill(filled ? Color.daisyAccent : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            filled ? Color.white.opacity(0.12) : Color.daisyDivider,
                            lineWidth: 0.5
                        )
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
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

    // MARK: - Permission refresh

    /// All request paths live in `SystemPermissions` (shared with
    /// Settings → Permissions); this is just the re-poll, wired to
    /// step changes + app foreground-activation by the observers on
    /// `body`. One call updates every permission row at once.
    private func refreshPermissionStates() {
        SystemPermissions.shared.refresh()
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
    /// contract: MainView branches on it (the AppSettings `didSet`
    /// persists it to UserDefaults), so the window swaps back to the
    /// ordinary split shell the moment it flips.
    private func finish() {
        settings.hasShownFirstRun = true
    }
}

#Preview {
    FirstRunView(settings: AppSettings())
}
