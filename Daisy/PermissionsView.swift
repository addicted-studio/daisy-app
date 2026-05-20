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
            permissionRow(
                title: "Microphone",
                caption: "Required. Daisy captures your audio locally — without mic access nothing can be recorded.",
                iconName: "mic.fill",
                isRequired: true,
                status: permissions.microphone,
                requestAction: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )

            permissionRow(
                title: "Accessibility",
                caption: "Required for the dictation hotkey — Daisy pastes the transcript into the active app via ⌘V. Without this, dictation falls back to copy-only.",
                iconName: "keyboard",
                isRequired: true,
                status: permissions.accessibility,
                requestAction: { permissions.requestAccessibility() },
                openSettings: permissions.openAccessibilitySettings
            )

            permissionRow(
                title: "Calendar",
                caption: "Optional. Lets Daisy auto-start recording when a meeting begins and tag transcripts with the right event.",
                iconName: "calendar",
                isRequired: false,
                status: permissions.calendar,
                requestAction: { Task { await permissions.requestCalendar() } },
                openSettings: permissions.openCalendarSettings
            )

            permissionRow(
                title: "Screen recording",
                caption: "Optional. Captures the other side of meetings via system audio (Zoom / Meet / Teams) — without it, recordings include only your mic.",
                iconName: "rectangle.on.rectangle",
                isRequired: false,
                status: permissions.screenRecording,
                requestAction: { permissions.requestScreenRecording() },
                openSettings: permissions.openScreenRecordingSettings
            )
        } header: {
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
        } footer: {
            Text("Daisy works entirely on-device. None of these permissions ship data anywhere — they only let macOS know which local APIs Daisy may call. You can revoke any of them later in System Settings → Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Row

    /// One row in the permissions dashboard. SF Symbol + title +
    /// caption on the left, a status pill, then an action button
    /// tailored to the current state.
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

            statusBadge(status: status, isRequired: isRequired)

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

    @ViewBuilder
    private func statusBadge(
        status: SystemPermissions.Status,
        isRequired: Bool
    ) -> some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.daisySuccess)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isRequired ? Color.daisyError : Color.daisyWarning)
        case .restricted:
            Label("Restricted", systemImage: "lock.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.daisyWarning)
        case .insufficient:
            Label("Write-only", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.daisyWarning)
        case .notDetermined:
            Label("Not requested", systemImage: "circle.dashed")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }

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
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .granted:
            Button("Revoke…") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
        }
    }
}
