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
//  block, links, studio note — just rebuilt with the surface
//  layout the rest of the detail pane uses (ScrollView + padded
//  sections) rather than Form. Form chrome read as "preferences",
//  which About is not.
//

import AppKit
import SwiftUI

struct AboutView: View {
    @Bindable private var updater = SparkleUpdater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                brandHeader

                // Updates lives directly under the version line —
                // natural pairing of "what version am I on" and "how
                // do I get newer ones". Apple's own About panels
                // historically had this same adjacency.
                updatesSection
                linksSection
                studioSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        // 2026-05-25 — merged the bottom-of-page "Daisy is built so
        // your meetings stay on your Mac…" paragraph into this header
        // subtitle. Pre-fix the page had two short value-prop
        // statements ~600pt apart: one under the title (Local
        // meeting capture for Mac.) and one at the very bottom
        // (full privacy explainer). The visual split made the
        // footer paragraph feel like fine print no one reads,
        // while the top subtitle was just a category descriptor.
        // Merged: the title pill carries both pieces — what it is
        // + what's on-device — and we drop the duplicate "for Mac"
        // from the original footer along the way. Trailing period
        // dropped per the Daisy caption rule (see
        // business/projects/daisy → Brand copy rules).
        HStack(alignment: .top, spacing: 16) {
            DaisyMark(size: 56, tint: .primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Daisy")
                    .font(.title.weight(.semibold))
                Text("Local meeting capture for Mac — audio, transcript, and summary all on-device by default. Cloud LLMs (Anthropic, OpenAI) and MCP integrations are strictly opt-in")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(versionLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .padding(.top, 2)
                    // 2026-05-27 — click-to-copy on the About header
                    // version line. Same affordance as the sidebar
                    // version pill in MainView; both copy
                    // "Daisy <version> (<build>)" so support pastes
                    // are uniform regardless of which surface the
                    // user clicked from. No icon / no visual change
                    // per Egor's constraint — discoverability via
                    // `.help` tooltip only. `.contentShape` widens
                    // the hit target to the full text frame.
                    .contentShape(Rectangle())
                    .onTapGesture { VersionInfo.copyToClipboardWithToast() }
                    .help("Click to copy version")
            }
            Spacer()
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Updates")
            // Single-row layout: leading icon + label/last-checked
            // VStack, manual Check button, toggle on the right edge.
            // Originally a two-row card with "Check now" as a separate
            // labelled action; consolidated after the second row read
            // as filler — the manual-check button is exactly the same
            // action a user lands on from the App menu anyway, no
            // need for a second presentation of it.
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .frame(width: 18) // 2026-05-25 — was 22, matched to SettingsView + PermissionsView icon column for cross-surface row-rhythm
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates")
                        .foregroundStyle(.primary)
                    Text(lastCheckedLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer()
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.daisyBgSidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )

            // Update channel (2026-06-08). OFF = stable releases only
            // (appcast items without a channel tag). ON = also offered
            // "beta"-channel builds — newest features first, less soak
            // time. Applies on the next update check, no restart.
            HStack(spacing: 12) {
                Image(systemName: "testtube.2")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get beta updates")
                        .foregroundStyle(.primary)
                    Text("Newest builds first — they've had less testing. The website always keeps the stable download.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: $updater.receiveBetaUpdates)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.daisyBgSidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
    }

    private var lastCheckedLine: String {
        if let last = updater.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last checked \(formatter.localizedString(for: last, relativeTo: Date()))"
        }
        return "Daisy will check daily once enabled."
    }

    // MARK: - Links

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Links")
            VStack(spacing: 0) {
                aboutRow(
                    icon: "globe",
                    title: "Website",
                    detail: "mydaisy.io",
                    url: URL(string: "https://mydaisy.io")
                )
                divider
                aboutRow(
                    icon: "lifepreserver",
                    title: "Support",
                    detail: "mydaisy.io/support",
                    url: URL(string: "https://mydaisy.io/support")
                )
                divider
                aboutRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Source code",
                    detail: "github.com/addicted-studio/daisy-app",
                    url: URL(string: "https://github.com/addicted-studio/daisy-app")
                )
                divider
                aboutRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Community",
                    detail: "Q&A, ideas, show-and-tell",
                    url: URL(string: "https://github.com/addicted-studio/daisy-app/discussions")
                )
                divider
                aboutRow(
                    icon: "doc.text",
                    title: "License",
                    detail: "Apache 2.0 — open source",
                    url: URL(string: "https://github.com/addicted-studio/daisy-app/blob/main/LICENSE")
                )
                divider
                aboutRow(
                    icon: "lock.shield",
                    title: "Privacy",
                    detail: "mydaisy.io/privacy",
                    url: URL(string: "https://mydaisy.io/privacy")
                )
                divider
                aboutRow(
                    icon: "envelope",
                    title: "Contact",
                    detail: "essazanov@pm.me",
                    url: URL(string: "mailto:essazanov@pm.me")
                )
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.daisyBgSidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Studio

    private var studioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Studio")
            VStack(spacing: 0) {
                aboutRow(
                    icon: "building.2",
                    title: "Made by",
                    detail: "Addicted Studio",
                    url: URL(string: "https://addicted.sh")
                )
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.daisyBgSidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
            // Bottom paragraph removed 2026-05-25 — merged into the
            // page-top brand header so the value-prop landed before
            // the user scrolled five rows of links instead of after.
        }
    }

    // MARK: - Pieces

    private var divider: some View {
        Rectangle()
            .fill(Color.daisyDivider)
            .frame(height: 0.5)
            .padding(.leading, 44) // align past the icon column
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    @ViewBuilder
    private func aboutRow(
        icon: String,
        title: String,
        detail: String,
        url: URL?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 18) // 2026-05-25 — was 22, matched to SettingsView + PermissionsView icon column for cross-surface row-rhythm consistency
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
