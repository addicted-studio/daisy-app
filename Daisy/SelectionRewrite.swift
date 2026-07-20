//
//  SelectionRewrite.swift
//  Daisy
//
//  "Rewrite selection in my voice" — a global hotkey that grabs the
//  selected text in ANY app (simulated ⌘C), rewrites it through the
//  user's Voice Profile on the selected summary provider, and pastes the
//  result back over the selection (simulated ⌘V). Fully local when the
//  provider is local. Goldfish-style act-anywhere, but scoped to an
//  explicit selection + hotkey — no ambient capture.
//
//  Flow (all on MainActor):
//    1. Preconditions: Voice Profile exists, Accessibility granted.
//    2. Snapshot clipboard → clear → simulate ⌘C → wait → read selection.
//    3. Rewrite with the polish prompt under a hard deadline.
//    4. Write result → simulate ⌘V (replaces the still-active selection).
//    5. Restore the original clipboard after a grace window.
//  Any failure restores the clipboard and toasts — never leaves the user
//  with a trampled pasteboard.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

@MainActor
final class SelectionRewrite {
    static let shared = SelectionRewrite()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SelectionRewrite")

    /// How long we wait for the frontmost app to service the ⌘C before
    /// reading the pasteboard.
    private static let copyGraceSeconds: Double = 0.25
    /// Provider deadline — selections can be longer than a dictation, so
    /// a bit more headroom than the dictation polish (8 s).
    private static let rewriteDeadlineSeconds: Double = 15
    /// Clipboard restore delay after the paste. Short — the ⌘V lands
    /// within a beat, and the user's prior clipboard should come back
    /// right away (same clipboard-courtesy as DictationPaste's quick
    /// restore).
    private static let restoreSeconds: TimeInterval = 1.5

    private var restoreTimer: Timer?
    private var pendingSnapshot: [[String: Data]]?
    private var pendingChangeCount: Int = 0
    /// Re-entrancy guard — a second hotkey press while a rewrite is in
    /// flight is ignored (the first one owns the clipboard).
    private var isRunning = false

    private init() {}

    // MARK: - Entry

    func trigger() async {
        guard !isRunning else { return }

        // Precondition 1: a voice profile to rewrite WITH.
        guard let instruction = VoiceProfileStore.shared.profile?.styleInstruction,
              !instruction.isEmpty else {
            ToastCenter.shared.show(
                String(localized: "Generate your Voice Profile first — open the Voice section."),
                style: .warning
            )
            return
        }
        // Precondition 2: Accessibility (we synthesize ⌘C/⌘V).
        if !AXIsProcessTrusted() {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            ToastCenter.shared.show(
                String(localized: "Rewriting needs Accessibility access — grant it in System Settings and try again."),
                style: .warning
            )
            return
        }

        isRunning = true
        defer { isRunning = false }

        // 2. Snapshot the clipboard, then copy the selection.
        cancelPendingRestore()
        let snapshot = captureClipboard()
        NSPasteboard.general.clearContents()
        let preCopyCount = NSPasteboard.general.changeCount
        postKeystroke(CGKeyCode(kVK_ANSI_C))
        try? await Task.sleep(for: .seconds(Self.copyGraceSeconds))

        let changed = NSPasteboard.general.changeCount != preCopyCount
        let selection = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard changed, !selection.isEmpty else {
            restore(snapshot)
            ToastCenter.shared.show(
                String(localized: "Select some text first, then press the rewrite shortcut."),
                style: .warning
            )
            return
        }

        // 3. Rewrite under a deadline (never hang the user's flow).
        ToastCenter.shared.show(String(localized: "Rewriting in your voice…"), style: .info)
        let rewritten = await RecordingSession.polishWithDeadline(
            text: selection,
            instruction: instruction,
            seconds: Self.rewriteDeadlineSeconds
        )
        guard let rewritten, !rewritten.isEmpty else {
            restore(snapshot)
            ToastCenter.shared.show(
                String(localized: "Couldn’t rewrite that — check your summary provider in Settings."),
                style: .error
            )
            return
        }

        // Feed the "fixes made by Daisy" widget (words the rewrite changed).
        let before = selection.split(whereSeparator: { $0.isWhitespace })
        let after = rewritten.split(whereSeparator: { $0.isWhitespace })
        UsageStats.shared.recordFixes(polished: after.difference(from: before).insertions.count)

        // 4. Paste the result over the (still-active) selection.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewritten, forType: .string)
        pendingChangeCount = NSPasteboard.general.changeCount
        postKeystroke(CGKeyCode(kVK_ANSI_V))
        ToastCenter.shared.show(
            String(localized: "Rewritten in your voice — your clipboard is coming right back."),
            style: .success
        )

        // 5. Give the paste time to land, then restore the old clipboard
        //    (unless the user copied something else meanwhile).
        pendingSnapshot = snapshot
        restoreTimer = Timer.scheduledTimer(
            withTimeInterval: Self.restoreSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingSnapshot = nil; self.restoreTimer = nil }
                guard let snapshot = self.pendingSnapshot,
                      NSPasteboard.general.changeCount == self.pendingChangeCount else { return }
                self.restore(snapshot)
            }
        }
    }

    // MARK: - Clipboard helpers

    private func captureClipboard() -> [[String: Data]] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            var out: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { out[type.rawValue] = data }
            }
            return out
        }
    }

    private func restore(_ snapshot: [[String: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (raw, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            return item
        }
        pb.writeObjects(items)
    }

    private func cancelPendingRestore() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        pendingSnapshot = nil
    }

    // MARK: - Keystroke

    /// Post ⌘+key (down/up pair wrapped in ⌘ down/up) to the session
    /// event tap — same mechanics as DictationPaste's ⌘V.
    private func postKeystroke(_ key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Couldn't create CGEventSource for keystroke")
            return
        }
        let cmd = CGKeyCode(kVK_Command)
        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
        else {
            log.error("CGEvent construction returned nil")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        let tap = CGEventTapLocation.cgSessionEventTap
        cmdDown.post(tap: tap)
        keyDown.post(tap: tap)
        keyUp.post(tap: tap)
        cmdUp.post(tap: tap)
    }
}
