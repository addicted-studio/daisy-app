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
                // Above the profile, not under it (Egor, 2026-07-30): the
                // profile text is the long block on this page — anything
                // parked below it is below the fold, and this switch is
                // the answer to "why does this say 0 of 300 when I have 76
                // recordings", which is a question you have BEFORE you
                // read the profile.
                includeMeetingsCard
                stateCard
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
        .task {
            // Covers the switch being flipped on in an earlier launch
            // before the Library had loaded. No-op once seeded.
            if store.includesMeetings, store.meetingCorpus.isEmpty {
                await seedFromLibrary()
            }
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
            Text("A profile of how you write, built from your dictations")
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
                Text("\(store.effectiveWords) of \(VoiceProfileStore.unlockWords) words")
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

    /// Opt-in switch for counting the user's own speech from meetings.
    ///
    /// Sits above the state card in EVERY state, not inside the
    /// pre-unlock card: it's the answer to "why does this say 0 of 300
    /// when I have 76 recordings" (2026-07-27 report), and it has to stay
    /// reachable after the profile exists so it can be turned back off —
    /// a switch that disappears once you're unlocked is a switch you
    /// can't undo.
    ///
    /// Off by default. The caption states the trade-off instead of
    /// selling the feature: a profile trained on call speech writes the
    /// way you talk on a call.
    private var includeMeetingsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { store.includesMeetings },
                    set: { isOn in
                        store.setIncludesMeetings(isOn)
                        guard isOn else { return }
                        Task { await seedFromLibrary() }
                    }
                )) {
                    Text("Count my speech from meetings too")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text(store.includesMeetings
                     ? String(localized: "Only your microphone is used — never the other side. Meeting speech is conversational, so expect a profile that writes closer to how you talk.")
                     : String(localized: "By default only dictation counts. Turn this on and Daisy also learns from what YOU said in meetings — your microphone only, never the other side."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fill the meeting corpus from transcripts already on disk.
    ///
    /// Refreshes SessionStore first: a user who opens Voice without
    /// passing through Home or Library has an empty session list, and
    /// seeding off that would silently add nothing — with the switch
    /// already flipped, `onChange` would never fire again to retry.
    /// `backfillFromMeetings` no-ops once the corpus holds anything, so
    /// running this more than once is free.
    private func seedFromLibrary() async {
        await SessionStore.shared.refresh()
        store.backfillFromMeetings(
            sessions: SessionStore.shared.sessions,
            displayName: settings.userDisplayName
        )
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
            // One continuous NSTextView-backed text body — same fix the
            // transcript and summary cards got (2026-07-25, Egor's
            // report): a stack of SwiftUI `Text`s with
            // .textSelection(.enabled) can't drag-select across view
            // boundaries, so selection stopped at every paragraph/bullet.
            // `includeStructural: false` = lede + sections/bullets only
            // (no "Meeting"/"Next actions"/follow-up frames — and an
            // imported profile duplicates its text into clientFollowUp,
            // which would render twice).
            //
            // ScrollableTextView, not SelectableTextView (2026-07-30,
            // Egor: "что-то поехало"). Two bugs, one cause — the bare
            // intrinsic-height NSTextView. Its text container is
            // zero-width until `sizeThatFits` pins it, so any layout pass
            // that asked for an ideal size instead of proposing a width
            // got AppKit's fitting size: the narrowest layout the text
            // admits, one hyphenated word per line in a ~55pt ribbon down
            // the left of a full-width card. And a 400-word profile
            // measured taller than the card it was given, so the tail was
            // clipped with no way to reach it. The scrollable variant
            // wraps to its own frame instead. Same move the Summary and
            // Transcript blocks already made.
            //
            // The cap is a backstop, not a reading height: this page
            // already scrolls, so a cap a real profile could reach would
            // put a second scroller inside the first one and swallow the
            // wheel over the card. It sits above any plausible profile and
            // below AppKit's ~16k-pt view-height ceiling, so a pathological
            // imported profile scrolls inside the card rather than being
            // clipped with no way to reach the end.
            ScrollableTextView(
                attributed: summaryAttributedString(
                    profile.display,
                    compact: true,
                    includeStructural: false
                ),
                maxHeight: 4000
            )
            .frame(maxWidth: .infinity, alignment: .leading)
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

// VoiceBulletRow removed 2026-07-25 — the profile card now renders
// through summaryAttributedString + SelectableTextView (one continuous
// selectable text body), same as the meeting summary cards.
