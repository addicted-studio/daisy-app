//
//  AboutView.swift
//  Daisy
//
//  Standalone About page shown from the sidebar (Home / History /
//  Settings / About). Previously this lived as a tab inside
//  SettingsView; promoted out so users find studio / contact /
//  license info in one obvious place instead of buried five clicks
//  deep in preferences.
//
//  Content mirrors the in-app About tab that existed before — brand
//  block, links, studio note. 2026-06-13: rebuilt onto the SAME
//  grouped-Form surface the rest of Settings uses (DictationView /
//  SettingsView: `Form { Section … } .formStyle(.grouped)
//  .scrollContentBackground(.hidden) .background(.daisyBgPrimary)`).
//  The earlier ScrollView + custom RoundedRectangle(daisyBgSidebar)
//  cards diverged from every other detail pane — different card
//  colour, grid, and insets. Switching to Form makes About's section
//  cards, colours, and row rhythm identical to Settings/Dictation.
//  The brand block sits borderless ABOVE the Form (a title header,
//  not a boxed card) so the 56pt logo keeps room to breathe.
//

import AppKit
import SwiftUI

struct AboutView: View {
    @Bindable private var updater = SparkleUpdater.shared

    var body: some View {
        Form {
            // Updates lives directly under the version line — natural
            // pairing of "what version am I on" and "how do I get newer
            // ones". Apple's own About panels historically had this same
            // adjacency.
            Section {
                // App version as the first row of Updates — pairs "what am
                // I on" with "how to get newer" (moved here from the brand
                // header). Click the row to copy "Daisy <version> (<build>)".
                HStack(spacing: 10) {
                    Image(systemName: "number")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(versionLine)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { VersionInfo.copyToClipboardWithToast() }
                .help("Click to copy version")

                // "Automatically check for updates" — manual Check button
                // on the trailing side (same action the App menu lands on)
                // plus the automatic-check toggle, with the last-checked
                // caption underneath. LabeledContent gives us the Settings
                // row grid; the trailing HStack carries the button + switch.
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Check for Updates…") {
                            updater.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.daisyTextPrimary)
                        .disabled(!updater.canCheckForUpdates)

                        Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatically check for updates")
                            Text(lastCheckedLine)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }

                // Update channel (2026-06-08). OFF = stable releases only
                // (appcast items without a channel tag). ON = also offered
                // "beta"-channel builds — newest features first, less soak
                // time. Applies on the next update check, no restart.
                Toggle(isOn: $updater.receiveBetaUpdates) {
                    HStack(spacing: 10) {
                        Image(systemName: "testtube.2")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get beta updates")
                            Text("Newest builds first — they've had less testing. The website always keeps the stable download.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Updates")
            }

            Section {
                aboutLinkRow(
                    icon: "globe",
                    title: "Website",
                    detail: "mydaisy.io",
                    url: URL(string: "https://mydaisy.io")
                )
                aboutLinkRow(
                    icon: "lifepreserver",
                    title: "Support",
                    detail: "mydaisy.io/support",
                    url: URL(string: "https://mydaisy.io/support")
                )
                aboutLinkRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Source code",
                    detail: "github.com/addicted-studio/daisy-app",
                    url: URL(string: "https://github.com/addicted-studio/daisy-app")
                )
                aboutLinkRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Community",
                    detail: "Q&A, ideas, show-and-tell",
                    url: URL(string: "https://github.com/addicted-studio/daisy-app/discussions")
                )
                aboutLinkRow(
                    icon: "doc.text",
                    title: "License",
                    detail: "Apache 2.0 — open source",
                    url: URL(string: "https://github.com/addicted-studio/daisy-app/blob/main/LICENSE")
                )
                aboutLinkRow(
                    icon: "lock.shield",
                    title: "Privacy",
                    detail: "mydaisy.io/privacy",
                    url: URL(string: "https://mydaisy.io/privacy")
                )
                aboutLinkRow(
                    icon: "envelope",
                    title: "Contact",
                    detail: "essazanov@pm.me",
                    url: URL(string: "mailto:essazanov@pm.me")
                )
            } header: {
                Text("Links")
            }

            Section {
                aboutLinkRow(
                    icon: "building.2",
                    title: "Made by",
                    detail: "Addicted Studio",
                    url: URL(string: "https://addicted.sh")
                )
            } header: {
                Text("Studio")
            }
            // Bottom paragraph removed 2026-05-25 — merged into the
            // page-top brand header so the value-prop landed before the
            // user scrolled five rows of links instead of after.
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.daisyBgPrimary)
    }

    // MARK: - Updates

    private var lastCheckedLine: String {
        if let last = updater.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last checked \(formatter.localizedString(for: last, relativeTo: Date()))"
        }
        return "Daisy will check daily once enabled."
    }

    // MARK: - Pieces

    /// One link row in the Settings row idiom: a leading title label and
    /// a trailing button that opens the URL. Built on `LabeledContent`
    /// so it inherits the same grid/insets as every other Form row in
    /// Settings (which don't carry leading icons — so neither does this).
    @ViewBuilder
    private func aboutLinkRow(
        icon: String,
        title: String,
        detail: String,
        url: URL?
    ) -> some View {
        LabeledContent {
            if let url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(detail)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title): \(detail)")
            } else {
                Text(detail).foregroundStyle(.secondary)
            }
        } label: {
            // Leading icon (secondary) + title — matches the icon rows in
            // Settings → Permissions (18pt icon column).
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
            }
        }
    }

    private var versionLine: String {
        // Displayed format ("Version X (build)") differs from the
        // clipboard payload ("Daisy X (build)") — the surrounding
        // About panel already labels itself "Daisy", so the in-UI
        // "Version" prefix avoids redundancy. See VersionInfo for
        // the support-paste payload.
        "Version \(VersionInfo.marketingVersion) (\(VersionInfo.buildNumber))"
    }
}

#Preview {
    AboutView()
        .frame(width: 640, height: 720)
}
