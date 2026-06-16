//
//  DictationView.swift
//  Daisy
//
//  Top-level sidebar page for the dictation user — a focused home for
//  the word-replacement dictionary and the rolling 24-hour history.
//  Promoted out of the Settings "Dictation" tab in 1.0.7.19 so it sits
//  alongside Home / Library / Connections in the sidebar rather than
//  buried in a Settings sub-tab.
//
//  Structure mirrors SettingsView's tab bodies (a `Form { … }
//  .formStyle(.grouped)` with section headers + footers). The two child
//  views (`DictationDictionaryView`, `DictationHistoryView`) are
//  self-contained singletons that render rows only — no Form / Section of
//  their own — so they slot straight into the Sections here, exactly as
//  they did in the old Settings tab.
//

import SwiftUI

struct DictationView: View {
    // Observe history so the header "Clear history" capsule appears /
    // disappears as entries are recorded or cleared.
    @Bindable private var history = DictationHistory.shared
    @State private var showingAddWord = false

    var body: some View {
        Form {
            Section {
                DictationDictionaryView()
            } header: {
                HStack {
                    Text("Vocabulary")
                    Spacer()
                    addWordButton
                }
            } footer: {
                Text("Fixed before pasting — names, brands, jargon.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                DictationHistoryView()
            } header: {
                HStack {
                    Text("Recent dictations")
                    Spacer()
                    if !history.entries.isEmpty {
                        clearHistoryButton
                    }
                }
            } footer: {
                Text("Last 24 hours. Tap to copy.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.daisyBgPrimary)
        .sheet(isPresented: $showingAddWord) {
            AddVocabularyView()
        }
    }

    // MARK: - Header capsule actions
    //
    // Pulled up to the section headers (Egor 2026-06-16): "Add word" sits
    // in the Vocabulary header's top-right corner and "Clear history" in
    // the Recent-dictations header — both capsule-shaped like the Library
    // Summarize pill. The child views now render rows only.

    private var addWordButton: some View {
        Button {
            showingAddWord = true
        } label: {
            Label("Add word", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .tint(Color.daisyTextPrimary)
        .textCase(nil)
    }

    private var clearHistoryButton: some View {
        Button(role: .destructive) {
            DictationHistory.shared.clear()
            ToastCenter.shared.show("History cleared", style: .success)
        } label: {
            Label("Clear history", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .tint(Color.daisyError)
        .textCase(nil)
    }
}
