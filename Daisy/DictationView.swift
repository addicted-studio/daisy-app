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
    var body: some View {
        Form {
            Section {
                DictationDictionaryView()
            } header: {
                Text("Word replacements")
            } footer: {
                Text("Daisy applies these to dictation before it pastes — handy for names, brands and jargon the model mishears.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section {
                DictationHistoryView()
            } header: {
                Text("Recent dictations")
            } footer: {
                Text("The last 24 hours of dictations, then auto-cleared. Tap one to copy it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
