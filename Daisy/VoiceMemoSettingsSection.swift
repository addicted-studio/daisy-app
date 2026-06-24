//
//  VoiceMemoSettingsSection.swift
//  Daisy
//
//  Settings → Transcription (bottom) → "Voice Memos" section. Opt-in
//  toggle to let Daisy import Apple Voice Memos recordings as
//  transcripts. Reading the library needs Full Disk Access — that
//  request now lives in Settings → Permissions (shown only while this
//  is enabled); this block just runs the import and reports via a toast.
//
//  Self-contained `Section` so SettingsView only needs a one-line
//  insertion into the Transcription tab's `Form`.
//

import SwiftUI

struct VoiceMemoImportSection: View {
    @Bindable var settings: AppSettings
    @Bindable private var scanner = VoiceMemoScanner.shared

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
            }

            if settings.ingestVoiceMemos {
                // Destination + folder picker on one row: "Saved to" label
                // on the left, the path and the "Choose folder…" button
                // grouped at the right (button hugs the far-right edge).
                LabeledContent("Saved to") {
                    HStack(spacing: 8) {
                        Text(destPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose folder…") {
                            if VoiceMemoFolder.presentPicker() != nil {
                                refreshDestPath()
                            }
                        }
                        .controlSize(.small)
                    }
                }

                // One-shot backfill over the whole library. Shows a live
                // spinner + running count while scanning, and a result
                // toast on completion (the button gave no feedback before).
                Button {
                    Task {
                        await scanner.scanNow(backfill: true)
                        announceResult()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if scanner.isScanning { ProgressView().controlSize(.small) }
                        Text(scanner.isScanning
                             ? "Importing… (\(scanner.importedThisRun))"
                             : "Process existing recordings")
                    }
                }
                .disabled(scanner.isScanning)
            }
        } header: {
            Text("Voice Memos")
        } footer: {
            if settings.ingestVoiceMemos {
                Text("Runs automatically once a day. Needs Full Disk Access to read your Voice Memos library — grant it in Settings → Permissions.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task { refreshDestPath() }
    }

    /// Report the outcome of a manual "Process existing" run as a toast —
    /// derived from the scan's resolved status + the imported count.
    private func announceResult() {
        switch scanner.lastStatus {
        case .ok:
            let n = scanner.importedThisRun
            ToastCenter.shared.show(
                n > 0 ? "Imported \(n) recording\(n == 1 ? "" : "s")" : "No new recordings to import",
                style: n > 0 ? .success : .info
            )
        case .needsFullDiskAccess:
            ToastCenter.shared.show("Needs Full Disk Access — grant it in Settings → Permissions.", style: .warning)
        case .noLibrary:
            ToastCenter.shared.show("No Voice Memos library found on this Mac.", style: .info)
        case .error(let msg):
            ToastCenter.shared.show("Import failed: \(msg)", style: .error)
        }
    }

    private func refreshDestPath() {
        destPath = (VoiceMemoFolder.resolveUserFolder() ?? VoiceMemoFolder.defaultFolder()).path
    }
}
