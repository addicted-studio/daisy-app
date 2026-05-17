//
//  IntegrationEditor.swift
//  Daisy
//
//  Modal editor for one MCPIntegration. Opened from Settings →
//  Auto-actions for both new and existing integrations.
//
//  Validates: name + URL + toolName all non-empty; URL parses to a
//  scheme-bearing URL; arguments template parses as JSON. Errors
//  surface inline next to the offending field rather than blocking
//  Save.
//

import SwiftUI

struct IntegrationEditor: View {
    let initial: MCPIntegration
    let onSave: (MCPIntegration) -> Void
    let onCancel: () -> Void

    @State private var draft: MCPIntegration
    @State private var templateError: String?

    init(initial: MCPIntegration, onSave: @escaping (MCPIntegration) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        self._draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                form
                    .padding(20)
            }
            Divider()
            footer
        }
        .background(Color.daisyBgPrimary)
        .onChange(of: draft.argumentsTemplate) { _, _ in
            validateTemplate()
        }
        .onAppear { validateTemplate() }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.circle.fill")
                .foregroundStyle(Color.daisyAccent)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(initial.name == "New integration" ? "New integration" : "Edit integration")
                    .font(.headline)
                Text("Push finished sessions into an MCP-compatible service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave(draft) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(16)
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(
                title: "Name",
                hint: "Shown in the kebab menu as `Send to {Name}`.",
                control: TextField("Notion · Meeting notes", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            )

            field(
                title: "Server URL",
                hint: "HTTP+SSE base URL of your MCP server. Daisy appends `/sse` to open the stream.",
                control: TextField("http://127.0.0.1:11436", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
            )

            field(
                title: "Tool name",
                hint: "Exact name of the tool to call. Check your server's `tools/list` output.",
                control: TextField("create_page", text: $draft.toolName)
                    .textFieldStyle(.roundedBorder)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Arguments template")
                    .font(.callout.weight(.medium))
                TextEditor(text: $draft.argumentsTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 200)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(templateError == nil ? Color.daisyDivider : Color.daisyError, lineWidth: 0.5)
                    )
                if let err = templateError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.daisyError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                placeholdersHelp
            }

            HStack {
                Toggle("Enabled", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                Spacer()
            }
        }
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

    /// Inline reference of the placeholders MCPDispatcher knows
    /// about. The list is duplicated here in display form; the
    /// authoritative table lives in MCPDispatcher.makePlaceholders.
    private var placeholdersHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholders")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("`{{title}}`, `{{date}}` (ISO-8601), `{{summary}}`, `{{actionItems}}` (joined with `; `), `{{actionItemsBullets}}` (one per line, leading `- `), `{{clientFollowUp}}`, `{{transcript}}`, `{{folder}}`, `{{locale}}`. All values are JSON-escaped before substitution.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: draft.baseURL)?.scheme != nil
            && !draft.toolName.trimmingCharacters(in: .whitespaces).isEmpty
            && templateError == nil
    }

    /// Validate the template by running a placeholder substitution
    /// with empty strings and trying to JSON-parse the result. We
    /// don't substitute real values because users haven't sent a
    /// session through it yet — we just want syntax validity.
    private func validateTemplate() {
        let probe = Self.replaceAllPlaceholders(in: draft.argumentsTemplate, with: "")
        guard let data = probe.data(using: .utf8) else {
            templateError = "Template isn't valid UTF-8."
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            templateError = nil
        } catch {
            templateError = "Template isn't valid JSON: \(error.localizedDescription)"
        }
    }

    private static let placeholderKeys = [
        "{{actionItemsBullets}}",
        "{{clientFollowUp}}",
        "{{actionItems}}",
        "{{transcript}}",
        "{{summary}}",
        "{{folder}}",
        "{{locale}}",
        "{{title}}",
        "{{date}}",
    ]

    private static func replaceAllPlaceholders(in template: String, with value: String) -> String {
        var t = template
        for key in placeholderKeys {
            t = t.replacingOccurrences(of: key, with: value)
        }
        return t
    }
}
