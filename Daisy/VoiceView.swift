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
    @State private var showingEdit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stateCard
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
        .sheet(isPresented: $showingImport) {
            VoiceImportView()
        }
        // Update + the polish toggle live as toolbar pills (CTA style, like
        // the other sections) — only once a profile exists.
        .toolbar {
            if store.hasProfile {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $settings.polishDictationInMyVoice) {
                        Text("Polish in my voice")
                            .padding(.horizontal, 10)
                    }
                    .toggleStyle(.button)
                    .help("Rewrite each dictation in your voice before it's pasted")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingEdit = true
                    } label: {
                        Text("Edit")
                            .padding(.horizontal, 10)
                    }
                    .help("Edit your profile text, or paste one carried over from another app (Granola, Wispr Flow…)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.generate() }
                    } label: {
                        Text("Update")
                            .padding(.horizontal, 10)
                    }
                    .help("Rebuild your profile from your latest dictations")
                }
            }
        }
        // Edit / replace the current profile text (pre-filled with the
        // active style instruction), in the Style-prompt editor.
        .sheet(isPresented: $showingEdit) {
            VoiceImportView(
                initialText: store.profile?.styleInstruction ?? "",
                startInStylePrompt: true
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Voice")
                // Serif display title, matching the Home greeting.
                .font(.system(.largeTitle, design: .serif).weight(.medium))
                .foregroundStyle(.primary)
            Text("A profile of how you write, built from your dictations.")
                .font(.callout)
                .foregroundStyle(.secondary)
            // "Built from N words · date" moved up here, under the title.
            if let profile = store.profile {
                Text("Built from \(profile.sampleWords.formatted(.number)) words · \(profile.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
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
                // Clean prose, like the meeting Summary block: no repeated
                // "Your voice" header (the page title already says it), no
                // accent-coloured section titles. Update / polish live in
                // the toolbar; the "built from" line moved under the title.
                if !profile.display.summary.isEmpty {
                    Text(profile.display.summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(profile.display.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                            VoiceBulletRow(bullet: bullet, depth: 0)
                        }
                    }
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
