//
//  VoiceView.swift
//  Daisy
//
//  The "Voice" sidebar section. Generates a local voice profile from the
//  user's own dictations and lets them turn on "polish dictation in my
//  voice" (a per-dictation rewrite conditioned on the profile).
//

import SwiftUI

struct VoiceView: View {
    @Bindable var settings: AppSettings
    @Bindable private var store = VoiceProfileStore.shared
    @State private var showingImport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stateCard
                polishCard
                Text("Your dictations are analyzed on your Mac. With a local summary provider the profile never leaves your Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
        .sheet(isPresented: $showingImport) {
            VoiceImportView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Voice")
                .font(.title2.weight(.semibold))
            Text("A profile of how you write, built from your dictations.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State

    @ViewBuilder
    private var stateCard: some View {
        switch store.state {
        case .idle:
            // Wispr-style: the profile isn't offered until enough real
            // dictation has accumulated — show progress until then.
            if store.isUnlocked {
                emptyCard
            } else {
                progressCard
            }
        case .generating:
            card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing your dictations…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let reason):
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    generateButton(title: "Try again")
                }
            }
        case .ready:
            if let profile = store.profile {
                profileCard(profile)
            } else {
                emptyCard
            }
        }
    }

    /// Pre-unlock: Daisy is still collecting enough dictation to profile
    /// from. Progress fills as the user dictates; flips to `emptyCard`
    /// ("ready!") at the threshold — same arc as Wispr Flow's profile.
    private var progressCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daisy is learning your voice")
                    .font(.headline)
                Text("Keep dictating — your Voice Profile unlocks automatically once Daisy has heard enough of you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: store.unlockProgress)
                    .progressViewStyle(.linear)
                    .tint(Color.daisyAccent)
                Text("\(store.corpusWords) of \(VoiceProfileStore.unlockWords) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                // Cold-start shortcut: seed from existing writing or a
                // ready-made style prompt instead of waiting.
                Button("Already have your style? Import it…") {
                    showingImport = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private var emptyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Voice Profile is ready!")
                    .font(.headline)
                Text("Daisy has heard enough of your dictation to learn your tone, phrasing, and quirks — so it can polish future dictations to sound like you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    generateButton(title: "Generate profile")
                    Button("Import instead…") {
                        showingImport = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    @ViewBuilder
    private func profileCard(_ profile: VoiceProfile) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your voice")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await store.generate() }
                    } label: {
                        Label("Update", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !profile.display.summary.isEmpty {
                    Text(profile.display.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(profile.display.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.daisyAccent)
                        ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                            VoiceBulletRow(bullet: bullet, depth: 0)
                        }
                    }
                }

                Text("Built from \(profile.sampleWords.formatted(.number)) words · \(profile.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Polish toggle

    private var polishCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.polishDictationInMyVoice) {
                    Text("Polish dictation in my voice")
                }
                .disabled(!store.hasProfile)
                Text(store.hasProfile
                     ? "Each dictation is rewritten in your voice before it's pasted. Adds a moment of processing on release."
                     : "Generate your profile first to enable this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.hasProfile {
                    Text("Tip: you can also rewrite selected text in any app — set a shortcut in Settings → Recording → Shortcuts (“Rewrite in my voice”).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func generateButton(title: LocalizedStringKey) -> some View {
        Button {
            Task { await store.generate() }
        } label: {
            Text(title)
                .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.daisyAccent)
        .controlSize(.regular)
    }
}

private struct VoiceBulletRow: View {
    let bullet: SummaryBullet
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Text(bullet.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 12)
            ForEach(Array(bullet.children.enumerated()), id: \.offset) { _, child in
                VoiceBulletRow(bullet: child, depth: depth + 1)
            }
        }
    }
}
