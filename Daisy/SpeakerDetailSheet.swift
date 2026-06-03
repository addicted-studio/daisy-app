//
//  SpeakerDetailSheet.swift
//  Daisy
//
//  Detail / edit surface for one known speaker, opened from
//  Settings → Speaker matching → (a speaker row). Lets the user edit
//  the CRM metadata on a `SpeakerProfile` — display name, the email
//  addresses that let calendar invites match this person, and a
//  free-form notes field — and forget the profile outright.
//
//  Scope on purpose: this edits METADATA only. The voice `embedding`,
//  `createdAt`, `lastSeenAt`, and `sessionCount` are owned by the
//  matching engine, never user-editable; they're shown read-only at
//  the bottom for context. Persistence goes through
//  `SpeakerProfileStore.updateMetadata`, which is the single point of
//  truth for email normalization + de-duplication, so this view keeps
//  raw text and lets the store clean it.
//
//  Chrome mirrors `IntegrationEditor`: a scrolling form, a divider,
//  and a footer with Cancel / Save (+ a left-aligned destructive
//  Forget). `.sheet(item:)` in SettingsView drives presentation; we
//  dismiss via the environment action.
//

import SwiftUI

struct SpeakerDetailSheet: View {
    /// Profile being edited. We key off the UUID (not the value type)
    /// so the read-only stat block always reflects the freshest store
    /// state, and a Forget from here reacts cleanly via observation.
    let profileID: UUID

    @Environment(\.dismiss) private var dismiss

    /// Observed so the body can fall back to the "removed" state if
    /// the profile disappears while the sheet is open (e.g. Forget),
    /// and so the read-only stats reflect the live profile. Same idiom
    /// as SettingsView's `@Bindable private var speakerStore`.
    @Bindable private var store = SpeakerProfileStore.shared

    // ── Editable drafts ──────────────────────────────────────────
    // Seeded once from the store snapshot at init (the Settings list
    // that opened this sheet already triggered `ensureLoaded`, so the
    // profile is in memory by now). Committed back on Save only.
    @State private var name: String
    @State private var emailRows: [EmailRow]
    @State private var notes: String
    @State private var confirmForget = false

    /// Stable-identity wrapper for an editable email row. Using a UUID
    /// id (rather than the array index) keeps SwiftUI bindings and
    /// row removal correct as the list mutates — index-as-id is the
    /// classic editable-list footgun.
    private struct EmailRow: Identifiable, Equatable {
        let id = UUID()
        var value: String
    }

    init(profileID: UUID) {
        self.profileID = profileID
        let p = SpeakerProfileStore.shared.profiles[profileID]
        _name = State(initialValue: p?.name ?? "")
        _emailRows = State(initialValue: (p?.emails ?? []).map { EmailRow(value: $0) })
        _notes = State(initialValue: p?.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.profiles[profileID] == nil {
                removedState
            } else {
                ScrollView {
                    form.padding(20)
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 440)
        .background(Color.daisyBgPrimary)
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(
                title: "Name",
                hint: "How this person appears on transcripts.",
                control: TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            )

            emailsSection

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.callout.weight(.medium))
                TextEditor(text: $notes)
                    .font(.callout)
                    .frame(minHeight: 88)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )
                Text("Anything you want to remember — role, company, how you met. Never used for matching; just for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            statsBlock
        }
    }

    /// Editable email list. Each row is a text field + a remove
    /// button; an "Add email" button appends a blank row. Blank /
    /// malformed entries are dropped by `updateMetadata` on Save, so
    /// we don't validate inline here — keeps the editor frictionless.
    private var emailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Emails")
                .font(.callout.weight(.medium))

            ForEach(emailRows) { row in
                HStack(spacing: 8) {
                    TextField("name@example.com", text: binding(for: row))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        emailRows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this email")
                }
            }

            Button {
                emailRows.append(EmailRow(value: ""))
            } label: {
                Label("Add email", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text("When a calendar meeting includes one of these addresses, Daisy recognizes this person — even when their voice sounds different that day (new mic, a cold, speakerphone).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read-only context — owned by the matching engine, shown so the
    /// user understands what Daisy has on this person without making
    /// it look editable.
    @ViewBuilder
    private var statsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = store.profiles[profileID] {
                statRow("Recordings", value: p.sessionCount == 1 ? "1 meeting" : "\(p.sessionCount) meetings")
                statRow("Last heard", value: relative(p.lastSeenAt))
                statRow("First named", value: relative(p.createdAt))
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.daisySuccess)
                Text("Voice fingerprint stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(Color.daisyTextPrimary)
                .monospacedDigit()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Forget", role: .destructive) { confirmForget = true }
                .tint(Color.daisyError)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .tint(Color.daisyAccent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .confirmationDialog(
            "Forget this speaker?",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("Forget \(displayName)", role: .destructive) {
                store.forget(profileID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Daisy deletes this person's voice fingerprint, emails, and notes from this Mac. Transcripts you've already labeled keep their names. This can't be undone.")
        }
    }

    // MARK: - Removed state

    /// Shown if the profile vanished from the store while the sheet
    /// was open (Forget, or a wipe from elsewhere). Keeps the sheet
    /// from rendering an empty editor against a dead id.
    private var removedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This speaker was removed.")
                .font(.callout)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Color.daisyAccent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Helpers

    private var displayName: String {
        store.profiles[profileID]?.name ?? "this speaker"
    }

    /// Stable binding into `emailRows` by row id (not index), so a
    /// field keeps editing the right row even after another row above
    /// it is removed.
    private func binding(for row: EmailRow) -> Binding<String> {
        Binding(
            get: { emailRows.first(where: { $0.id == row.id })?.value ?? "" },
            set: { newValue in
                if let idx = emailRows.firstIndex(where: { $0.id == row.id }) {
                    emailRows[idx].value = newValue
                }
            }
        )
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func save() {
        // Store normalizes + de-dupes emails and ignores a blank name,
        // so we hand it raw drafts. Notes pass through verbatim.
        store.updateMetadata(
            id: profileID,
            name: name,
            emails: emailRows.map(\.value),
            notes: notes
        )
        dismiss()
    }

    private func field<Control: View>(
        title: String,
        hint: String,
        control: Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
            control
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
