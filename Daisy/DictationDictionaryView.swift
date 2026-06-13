//
//  DictationDictionaryView.swift
//  Daisy
//
//  Editor for the dictation custom-vocabulary table
//  (`DictationDictionary`). Renders a list of `from → to` rows with
//  inline editing, per-row delete, an Add button, and an empty state.
//
//  Embedding contract: this view renders ONLY rows + controls — no
//  `Form`, no `Section` of its own. The caller is expected to drop it
//  inside a Settings `Form { Section { … } }`, e.g. a future "Dictation"
//  tab:
//
//      Section {
//          DictationDictionaryView()
//      } header: {
//          Text("Word replacements")
//      }
//
//  Styling mirrors the other Settings rows (callout-weight titles,
//  `.roundedBorder` text fields, `.bordered`/`.small` secondary buttons,
//  `Color.daisy*` tokens) so it sits seamlessly next to the existing
//  speaker-profile and storage rows.
//

import SwiftUI

struct DictationDictionaryView: View {
    /// The shared store. `@Bindable` so row edits and add/delete drive
    /// observation and re-render the list in place.
    @Bindable private var dictionary = DictationDictionary.shared

    /// Id of the row whose `from` field should grab focus — set right
    /// after `add()` so a new row is immediately typeable without a
    /// manual click.
    @FocusState private var focusedField: Field?

    /// Field identity for `@FocusState`. We only auto-focus the `from`
    /// side of a freshly-added row; the `to` field is reached by Tab.
    private enum Field: Hashable {
        case from(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One-line explainer in Daisy's plain voice. Caption styling
            // matches the per-section helper text used elsewhere in
            // Settings (e.g. the speaker-match-mode help).
            Text("Fix words dictation tends to mishear. Before pasting, Daisy swaps each entry on the left for the text on the right — handy for names, brands, and jargon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if dictionary.replacements.isEmpty {
                emptyState
            } else {
                rows
            }

            addButton
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        // Mirrors `SettingsView.speakerProfilesRow`'s empty placeholder
        // — icon + secondary line, left-aligned — so the two management
        // surfaces feel like siblings.
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
            Text("No replacements yet.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Column captions so the direction of the swap is legible
            // before the user has filled anything in.
            HStack(spacing: 8) {
                Text("Heard")
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Spacer matching the arrow column so the two captions
                // sit over their fields.
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.clear)
                Text("Replace with")
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Spacer matching the trailing delete button column.
                Color.clear.frame(width: 22)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)

            ForEach(dictionary.replacements) { replacement in
                row(for: replacement)
            }
        }
    }

    @ViewBuilder
    private func row(for replacement: DictationReplacement) -> some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: binding(for: replacement, keyPath: \.from),
                prompt: Text("e.g. claude")
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .from(replacement.id))
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            TextField(
                "",
                text: binding(for: replacement, keyPath: \.to),
                prompt: Text("e.g. Claude")
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)

            // Per-row delete. Borderless icon button with a destructive
            // tint — distinct hit target from the text fields so a
            // mis-click can't wipe a row. Matches the "Forget" idiom in
            // the speaker list (there it's a bordered word; here a
            // compact glyph keeps the row from getting too wide).
            Button {
                dictionary.remove(replacement)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Color.daisyError)
            }
            .buttonStyle(.borderless)
            .help("Remove this replacement")
        }
    }

    // MARK: - Add

    @ViewBuilder
    private var addButton: some View {
        Button {
            let id = dictionary.add()
            // Defer focus to the next runloop tick so the row exists in
            // the view tree before we try to focus its field.
            DispatchQueue.main.async {
                focusedField = .from(id)
            }
        } label: {
            Label("Add replacement", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.daisyTextPrimary)
    }

    // MARK: - Binding helper

    /// A two-way binding into a single field of one rule. Reads the
    /// freshest copy from the store on `get`, and routes `set` through
    /// `update(_:)` so every keystroke persists. Falls back to the
    /// passed-in value if the row vanished mid-edit (defensive — keeps
    /// the field from binding to a stale optional).
    private func binding(
        for replacement: DictationReplacement,
        keyPath: WritableKeyPath<DictationReplacement, String>
    ) -> Binding<String> {
        Binding(
            get: {
                let current = dictionary.replacements.first { $0.id == replacement.id } ?? replacement
                return current[keyPath: keyPath]
            },
            set: { newValue in
                var updated = dictionary.replacements.first { $0.id == replacement.id } ?? replacement
                updated[keyPath: keyPath] = newValue
                dictionary.update(updated)
            }
        )
    }
}
