//
//  PermissionsView.swift
//  Daisy
//
//  Dashboard for the four system privacy permissions Daisy uses.
//  Lives as a tab inside Settings (`SettingsTab.permissions`) because
//  it's about local OS-level access — not external service
//  integrations. Granola / Wispr Flow / MacWhisper put their
//  permission panes in Settings too; this matches macOS convention.
//
//  Each row encodes status as a coloured badge + caption + action
//  button (Request access for `.notDetermined`, Open System
//  Settings… for `.denied`/`.restricted`, Revoke… for `.granted`).
//  State is refreshed on app focus via `SystemPermissions.shared`,
//  so external changes in System Settings reflect immediately
//  when the user comes back to Daisy.
//

import SwiftUI

struct PermissionsView: View {
    @Bindable private var permissions = SystemPermissions.shared

    var body: some View {
        Form {
            permissionsSection
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Section

    @ViewBuilder
    private var permissionsSection: some View {
        Section {
            // 2026-05-25 — captions trimmed to one short sentence
            // each. Pre-fix every row carried 2-3 sentences with a
            // "Required." / "Optional." prefix, repeating what the
            // explicit `Optional` pill next to the title already
            // said (and what its absence said for required rows).
            // The result was a wall of paragraphs the user had to
            // skim through before figuring out what to click. New
            // shape: badge tells you required vs optional, caption
            // tells you why this one knob exists. Detail / failure
            // modes still live in their respective help text and
            // toasts at the moment they matter, not preemptively
            // here.
            permissionRow(
                title: "Microphone",
                caption: "Captures your voice",
                iconName: "mic.fill",
                isRequired: true,
                status: permissions.microphone,
                requestAction: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )

            permissionRow(
                title: "Accessibility",
                caption: "Lets dictation paste into any app",
                iconName: "keyboard",
                isRequired: true,
                status: permissions.accessibility,
                requestAction: { permissions.requestAccessibility() },
                openSettings: permissions.openAccessibilitySettings
            )

            permissionRow(
                title: "Calendar",
                caption: "Auto-starts recording at meeting times",
                iconName: "calendar",
                isRequired: false,
                status: permissions.calendar,
                requestAction: { Task { await permissions.requestCalendar() } },
                openSettings: permissions.openCalendarSettings
            )

            permissionRow(
                title: "Screen recording",
                caption: "Captures the other side of meetings",
                iconName: "rectangle.on.rectangle",
                isRequired: false,
                status: permissions.screenRecording,
                requestAction: { permissions.requestScreenRecording() },
                openSettings: permissions.openScreenRecordingSettings
            )

            permissionRow(
                title: "Notifications",
                caption: "Banner when Daisy auto-starts or saves",
                iconName: "bell",
                isRequired: false,
                status: permissions.notifications,
                requestAction: { permissions.requestNotifications() },
                openSettings: permissions.openNotificationSettings
            )
        } header: {
            // 2026-05-25 — promoted the privacy explainer from the
            // Section footer up to the header, immediately under
            // "System access". Pre-fix it sat at the very bottom
            // of the Permissions tab below five rows of buttons,
            // i.e. exactly where nobody reads it. The whole point
            // of the paragraph is "don't worry, these don't ship
            // data anywhere" — that reassurance has to land BEFORE
            // the user starts approving prompts, not after.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("System access")
                    Spacer()
                    if permissions.needsAttention {
                        Label("Required permission missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.daisyWarning)
                    } else if permissions.hasAllRequiredGranted && permissions.hasAllOptionalGranted {
                        Label("All granted", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.daisySuccess)
                    }
                }
                Text("Daisy works entirely on-device. None of these permissions ship data anywhere — they only let macOS know which local APIs Daisy may call. You can revoke any of them later in System Settings → Privacy & Security")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Row

    /// One row in the permissions dashboard. SF Symbol + title +
    /// caption on the left, then the action button. The status itself
    /// is communicated by two existing signals — icon colour (green
    /// = granted, red/orange = needs attention, secondary = idle)
    /// and the action button's text (Request / Open Settings… /
    /// Revoke…) — so the explicit "Granted / Not requested" pill
    /// in between was redundant visual noise. Removed in 1.0.5.
    @ViewBuilder
    private func permissionRow(
        title: String,
        caption: String,
        iconName: String,
        isRequired: Bool,
        status: SystemPermissions.Status,
        requestAction: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.callout)
                .foregroundStyle(iconColor(status: status, isRequired: isRequired))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    if !isRequired {
                        Text("Optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.15), in: Capsule())
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            actionButton(
                status: status,
                requestAction: requestAction,
                openSettings: openSettings
            )
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    // MARK: - Cell pieces

    private func iconColor(
        status: SystemPermissions.Status,
        isRequired: Bool
    ) -> Color {
        switch status {
        case .granted:                       return Color.daisySuccess
        case .denied, .restricted:           return isRequired ? Color.daisyError : Color.daisyWarning
        case .insufficient:                  return Color.daisyWarning
        case .notDetermined:                 return .secondary
        }
    }

    // statusBadge(...) removed in 1.0.5 — row state is communicated
    // by `iconColor(status:isRequired:)` on the leading SF Symbol +
    // the action button's text (Request / Open Settings… / Revoke…).
    // Section header still surfaces "Required permission missing"
    // when needsAttention, which is the overall warning a user
    // glancing at Settings actually needs.

    @ViewBuilder
    private func actionButton(
        status: SystemPermissions.Status,
        requestAction: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        switch status {
        case .notDetermined:
            Button("Request") { requestAction() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.daisyAccent)
        case .denied, .insufficient, .restricted:
            // .restricted = managed device, the user can't toggle but
            // surfacing the deeplink anyway in case an admin can act.
            // 2026-05-26 — explicit `.tint(Color.daisyTextPrimary)`
            // because the default `.bordered` tint on Daisy's cream
            // surface collapses into the background (washed-out
            // orange-on-cream — Egor flagged the row as unactionable-
            // looking). Inking the button gives it readable text +
            // a dark outline without piling another orange element
            // on a row that already accents in cinnamon (icon +
            // "Optional" pill + title).
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
        case .granted:
            Button("Revoke…") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
        }
    }
}
