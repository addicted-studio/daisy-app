//
//  DictationHistoryView.swift
//  Daisy
//
//  Read-only list of the user's recent dictations (`DictationHistory`),
//  shown in Settings. Each row is the dictated text plus a relative
//  timestamp; tapping a row re-copies that text to the clipboard. A
//  destructive "Clear history" control empties the log. There's nothing
//  to edit here — the history records itself as a side effect of
//  dictation — so this is purely a recall surface.
//
//  Embedding contract: this view renders ONLY rows + controls — no
//  `Form`, no `Section` of its own. The caller is expected to drop it
//  inside a Settings `Form { Section { … } }` (e.g. a "Dictation" tab),
//  exactly like its sibling `DictationDictionaryView`:
//
//      Section {
//          DictationHistoryView()
//      } header: {
//          Text("Recent dictations")
//      }
//
//  Styling mirrors `DictationDictionaryView` and the other Settings rows
//  (caption helper text, callout-weight body, `.bordered`/`.small`
//  buttons, `Color.daisy*` tokens, `ToastCenter` for the copy toast) so
//  it sits seamlessly next to the dictionary editor.
//

import AppKit
import SwiftUI

struct DictationHistoryView: View {
    /// The shared store. `@Bindable` keeps the list in sync as entries are
    /// recorded (while Settings is open) or cleared.
    @Bindable private var history = DictationHistory.shared

    /// Relative-time formatter for the per-row timestamp ("3 minutes
    /// ago"). Held once rather than rebuilt per row.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One-line explainer in Daisy's plain voice — sets the privacy
            // expectation (local, auto-expiring) up front. Caption styling
            // matches the per-section helper text used elsewhere.
            Text("Kept on your Mac for 24 hours, then deleted. Tap to copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if history.entries.isEmpty {
                emptyState
            } else {
                rows
                clearButton
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        // Mirrors `DictationDictionaryView.emptyState` — icon + secondary
        // line, left-aligned — so the two dictation surfaces feel like
        // siblings.
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Text("Nothing in the last 24 hours.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(history.entries) { entry in
                row(for: entry)
                // Hairline divider between entries, matching the divider
                // idiom used elsewhere in Settings lists.
                if entry.id != history.entries.last?.id {
                    Divider()
                        .overlay(Color.daisyDivider)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: DictationEntry) -> some View {
        Button {
            copy(entry)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.callout)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())   // whole row is the hit target
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    // MARK: - Clear

    @ViewBuilder
    private var clearButton: some View {
        // Destructive, low-emphasis: bordered + small to match the
        // dictionary's "Add" button weight, tinted error-red and labelled
        // destructively so it reads as the dangerous action it is.
        Button(role: .destructive) {
            history.clear()
            ToastCenter.shared.show("History cleared", style: .success)
        } label: {
            Label("Clear history", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.daisyError)
    }

    // MARK: - Copy

    /// Re-copy a recorded dictation to the clipboard and confirm with a
    /// toast. Writes plain text only — the same string `DictationPaste`
    /// originally placed there.
    private func copy(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        ToastCenter.shared.show("Copied", style: .success)
    }
}
