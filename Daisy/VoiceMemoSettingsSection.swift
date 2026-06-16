//
//  VoiceMemoSettingsSection.swift
//  Daisy
//
//  Settings → Recording → "Voice Memos" section. Opt-in toggle to let
//  Daisy import Apple Voice Memos recordings as transcripts. Reading
//  the Voice Memos library needs Full Disk Access — surfaced here with
//  a one-click jump to System Settings + a live status row.
//
//  Self-contained `Section` so SettingsView only needs a one-line
//  insertion into the Recording tab's `Form`.
//

import SwiftUI

struct VoiceMemoImportSection: View {
    @Bindable var settings: AppSettings
    @Bindable private var scanner = VoiceMemoScanner.shared

    @State private var access: VoiceMemoLibrary.AccessStatus = .ok
    @State private var destPath: String = ""

    var body: some View {
        Section {
            Toggle(isOn: $settings.ingestVoiceMemos) {
                Text("Import Voice Memos")
                Text("Daisy checks once a day and transcribes new recordings into a notes folder you pick below — separate from meeting sessions. No summaries — fully on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.ingestVoiceMemos) { _, newValue in
                scanner.onToggle(enabled: newValue)
                if newValue { refreshAccess() }
            }

            if settings.ingestVoiceMemos {
                accessRow

                if !destPath.isEmpty {
                    LabeledContent("Saved to") {
                        Text(destPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Button("Choose folder…") {
                    if VoiceMemoFolder.presentPicker() != nil {
                        refreshDestPath()
                    }
                }
                .controlSize(.small)

                Button {
                    Task { await scanner.scanNow(backfill: true) }
                } label: {
                    if scanner.isScanning {
                        Text("Importing… (\(scanner.importedThisRun))")
                    } else {
                        Text("Process existing recordings")
                    }
                }
                .disabled(scanner.isScanning || access != .ok)
            }
        } header: {
            Text("Voice Memos")
        } footer: {
            if settings.ingestVoiceMemos, access == .needsFullDiskAccess {
                Text("Daisy needs Full Disk Access to read your Voice Memos library. Grant it in System Settings, then reopen this tab.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            refreshAccess()
            refreshDestPath()
        }
    }

    @ViewBuilder
    private var accessRow: some View {
        switch access {
        case .ok:
            Label("Voice Memos library connected", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsFullDiskAccess:
            HStack {
                Label("Needs Full Disk Access", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Full Disk Access") {
                    SystemPermissions.shared.openFullDiskAccessSettings()
                }
            }
        case .noLibrary:
            Label("No Voice Memos library found on this Mac", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshAccess() {
        access = VoiceMemoLibrary.accessStatus()
    }

    private func refreshDestPath() {
        destPath = (VoiceMemoFolder.resolveUserFolder() ?? VoiceMemoFolder.defaultFolder()).path
    }
}
