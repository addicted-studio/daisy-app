//
//  VoiceImportView.swift
//  Daisy
//
//  Seed the Voice Profile without waiting for the dictation corpus to
//  fill — for users arriving from another dictation app or who simply
//  have their own writing at hand. Two modes:
//    • Writing samples — paste / import .txt/.md of the user's OWN text;
//      feeds the same corpus the unlock bar tracks (may unlock at once).
//    • Style prompt — paste a ready-made style instruction (e.g. carried
//      over from another tool); installs the profile immediately.
//

import SwiftUI
import UniformTypeIdentifiers

struct VoiceImportView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case samples
        case instruction
        var id: String { rawValue }
    }

    @State private var mode: Mode
    // Each tab keeps its OWN text: pasting writing samples must not bleed
    // into the style-prompt field (or vice versa) — they're different
    // inputs (Egor 2026-07-22). Was a single shared `text`, which made
    // both tabs show the same content.
    @State private var samplesText: String
    @State private var instructionText: String
    @State private var showingFileImporter = false

    /// `initialText` pre-fills the editor (e.g. the current profile's style
    /// instruction, for editing/replacing); `startInStylePrompt` opens
    /// straight in the "Style prompt" tab and seeds THAT tab. Both default
    /// to fresh-import (empty).
    init(initialText: String = "", startInStylePrompt: Bool = false) {
        _mode = State(initialValue: startInStylePrompt ? .instruction : .samples)
        _instructionText = State(initialValue: startInStylePrompt ? initialText : "")
        _samplesText = State(initialValue: startInStylePrompt ? "" : initialText)
    }

    /// The text field for the currently-selected tab.
    private var activeText: Binding<String> {
        mode == .samples ? $samplesText : $instructionText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your Voice Profile")
                .font(.title3.weight(.semibold))

            // Same glass tab strip as the rest of the app (Dictation /
            // Connections / Settings) — a plain View, so it works inline in
            // this sheet too, not just in a window toolbar.
            GlassSegmentedControl(
                selection: $mode,
                segments: [
                    .init(value: .samples, title: String(localized: "My writing")),
                    .init(value: .instruction, title: String(localized: "Style prompt")),
                ]
            )

            Text(mode == .samples
                 ? "Paste your own writing — emails, posts, notes, or an export from another dictation app. Daisy learns your voice from it, same as from dictation."
                 : "Already have a style instruction from another tool? Paste it — Daisy will use it as your profile right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: activeText)
                .font(.body)
                .frame(minHeight: 180)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
                )

            HStack(spacing: 10) {
                if mode == .samples {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import file…", systemImage: "doc")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // Neutral grey label (was the app's orange accent tint).
                    .tint(Color.daisyTextSecondary)
                Button(mode == .samples ? "Add to profile" : "Use as profile") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // Neutral prominent (was orange accent).
                .tint(Color.daisyTextPrimary)
                .disabled(activeText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                ToastCenter.shared.show(String(localized: "Couldn't read that file."), style: .error)
                return
            }
            // Import only appears in the "My writing" tab → append there.
            samplesText = samplesText.isEmpty ? content : samplesText + "\n\n" + content
        }
    }

    private func apply() {
        let store = VoiceProfileStore.shared
        switch mode {
        case .samples:
            let added = store.importSamples(samplesText)
            if store.isUnlocked {
                ToastCenter.shared.show(
                    String(localized: "Added \(added) words — your Voice Profile is ready to generate."),
                    style: .success
                )
            } else {
                ToastCenter.shared.show(
                    String(localized: "Added \(added) words toward your Voice Profile."),
                    style: .success
                )
            }
        case .instruction:
            store.setCustomInstruction(instructionText)
            ToastCenter.shared.show(
                String(localized: "Style prompt installed — Daisy will polish in this voice."),
                style: .success
            )
        }
        dismiss()
    }
}
