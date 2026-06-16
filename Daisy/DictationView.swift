//
//  DictationView.swift
//  Daisy
//
//  Top-level sidebar page for the dictation user — a focused home for
//  the word-replacement dictionary and the rolling 24-hour history.
//  Promoted out of the Settings "Dictation" tab in 1.0.7.19 so it sits
//  alongside Home / Library / Connections in the sidebar.
//
//  Split into two horizontal tabs (Egor 2026-06-16) via a segmented
//  switcher at the top — "Vocabulary" and "History" — instead of two
//  stacked Form sections. Each tab is a `Form { Section { … } }` whose
//  child view (`DictationDictionaryView` / `DictationHistoryView`)
//  renders rows only. "Add word" lives in the window toolbar (top-right,
//  Vocabulary tab only); "Clear history" in the History tab's header.
//

import SwiftUI

struct DictationView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case vocabulary = "Vocabulary"
        case history = "History"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .vocabulary
    @State private var showingAddWord = false
    // Observe history so the "Clear history" capsule appears / disappears
    // as entries are recorded or cleared.
    @Bindable private var history = DictationHistory.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            switch tab {
            case .vocabulary: vocabularyTab
            case .history:    historyTab
            }
        }
        .background(Color.daisyBgPrimary)
        .sheet(isPresented: $showingAddWord) {
            AddVocabularyView()
        }
        .toolbar {
            // "Add word" in the window toolbar top-right (like the Library
            // "Summarize" pill) — only relevant on the Vocabulary tab.
            if tab == .vocabulary {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddWord = true
                    } label: {
                        Text("Add word")
                            .padding(.horizontal, 10)
                    }
                    .help("Add a word to your dictation vocabulary")
                }
            }
        }
    }

    // MARK: - Tabs

    private var vocabularyTab: some View {
        Form {
            Section {
                DictationDictionaryView()
            } footer: {
                Text("Fixed before pasting — names, brands, jargon.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var historyTab: some View {
        Form {
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
