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
                // Current version — name on the left, number + a copy button
                // on the right. Click it to copy "Daisy <version> (<build>)"
                // for support pastes.
                LabeledContent {
                    Button {
                        VersionInfo.copyToClipboardWithToast()
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(VersionInfo.marketingVersion) (\(VersionInfo.buildNumber))")
                                .monospacedDigit()
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy version")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("Current version")
                    }
                }

                // Automatic update — the auto-check toggle plus a manual
                // "Check for Updates…" (same action as the App menu). Both
                // controls regular-size so the switch matches the one below.
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
                            .labelsHidden()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("Automatic update")
                    }
                }

                Toggle(isOn: $updater.receiveBetaUpdates) {
                    HStack(spacing: 10) {
                        Image(systemName: "testtube.2")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text("Get beta updates")
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
}

#Preview {
    AboutView()
        .frame(width: 640, height: 720)
}
