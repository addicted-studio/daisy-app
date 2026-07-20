//
//  DictationPaste.swift
//  Daisy
//
//  Glue between dictation-mode end-of-recording and the user's
//  active text field. Three jobs:
//
//   1. Save the current clipboard contents (text + any other
//      pasteboard types) before we trample them.
//   2. Write the transcript and (if Accessibility permission is
//      granted) simulate ⌘V so the text lands in whatever field
//      the user has focused — true "Wispr Flow parity". When
//      permission is missing or the user denies, fall back to a
//      toast prompting manual ⌘V.
//   3. After a 10 s grace window, restore the previous clipboard
//      so the user's existing copy/paste state isn't permanently
//      clobbered by a one-off dictation. Skipped if the user has
//      already copied something else (detected via the pasteboard
//      change counter) or dictated again (cancellable timer).
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Singleton coordinator for the dictation paste flow.
///
/// `@MainActor` because every operation touches `NSPasteboard`,
/// `NSWorkspace`, and our shared `ToastCenter`. Held by
/// `RecordingSession` (via shared instance) so the 10 s restore
/// timer survives across the brief window where Daisy might
/// release its session reference and pick a new one up.
@MainActor
final class DictationPaste {
    static let shared = DictationPaste()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationPaste")

    /// Snapshot of the items in the pasteboard at the moment we
    /// started writing the transcript. Restored 10 s later if
    /// nothing else has been copied in the meantime.
    private struct ClipboardSnapshot: Sendable {
        let items: [[String: Data]]    // [type-string → raw data]
        let changeCountAfterOurWrite: Int
    }

    private var pendingSnapshot: ClipboardSnapshot?
    private var restoreTimer: Timer?

    /// Total seconds the transcript stays on the clipboard before
    /// we (optionally) restore the previous contents. Long enough
    /// that the user can switch apps, find the right field, and
    /// hit ⌘V without rushing. Short enough that the previous
    /// clipboard isn't permanently lost.
    static let retentionSeconds: TimeInterval = 10

    /// Restore delay when the AUTO-paste succeeded: the ⌘V has already
    /// landed, so the transcript only needs to survive in the pasteboard
    /// long enough for the frontmost app to service the keystroke. Short
    /// on purpose — the user's prior clipboard (logs, a link, …) comes
    /// back almost immediately instead of being held hostage for 10 s
    /// (Egor, 2026-07-14: "надиктовал команду → иду вставлять логи, а их
    /// уже нет").
    static let quickRestoreSeconds: TimeInterval = 1.5

    private init() {}

    // MARK: - Public entry

    /// Run the full post-dictation flow:
    ///   1. Snapshot current clipboard
    ///   2. Write transcript
    ///   3. Try auto-paste via simulated ⌘V (needs Accessibility)
    ///   4. Schedule restore-previous-clipboard in 10 s
    ///
    /// `transcript` is trimmed by the caller — pass empty string
    /// to skip clipboard work entirely (still shows a "nothing
    /// transcribed" toast).
    func handle(transcript: String) {
        guard !transcript.isEmpty else {
            ToastCenter.shared.show(
                String(localized: "Dictation stopped — nothing was transcribed."),
                style: .warning
            )
            return
        }

        // Apply the user's custom-vocabulary replacements ("claude" →
        // "Claude", "daisy app" → "Daisy", …) BEFORE anything touches the
        // pasteboard, so the corrected text is what gets written, copied,
        // and pasted. `DictationDictionary` is `@MainActor` and we're
        // already on the MainActor here (this method is MainActor-isolated
        // and the sole caller — `RecordingSession`, itself `@MainActor` —
        // invokes it synchronously), so this is a plain same-actor call:
        // no await, no snapshot, no actor hop needed. `apply` returns the
        // input unchanged when the table is empty, so this is a no-op for
        // users who never set up a dictionary.
        let (transcript, dictionaryFixes) = DictationDictionary.shared.applyCounting(to: transcript)
        // Feed the Home "fixes made by Daisy" widget.
        UsageStats.shared.recordFixes(dictionary: dictionaryFixes)

        // Log the final, about-to-be-pasted text to the rolling 24-hour
        // dictation history so the user can glance back / re-copy it later.
        // Placed AFTER `apply(to:)` so the record matches exactly what
        // lands in the user's field (dictionary already applied). Like
        // `DictationDictionary`, `DictationHistory` is `@MainActor` and
        // we're already on the MainActor here, so this is a plain
        // synchronous same-actor call — no await, no hop. `record` ignores
        // empty/whitespace-only input, so a stray blank transcript that
        // slips past the early guard above still won't pollute the log.
        DictationHistory.shared.record(transcript)

        // Grow the persistent voice-profile corpus (Wispr-style: the
        // profile unlocks once enough real dictation has accumulated).
        // Placed before the AX/clipboard fork so every successful
        // dictation counts regardless of how it lands in the field.
        VoiceProfileStore.shared.appendDictation(transcript)

        // 0. Best path: insert DIRECTLY into the focused text field via
        //    the Accessibility API — the pasteboard is never touched, so
        //    whatever the user had copied (logs, a link…) survives
        //    untouched. Works in most native apps; web views / Electron
        //    and secure fields often refuse, in which case we fall through
        //    to the clipboard route below.
        if attemptAXInsert(transcript) {
            ToastCenter.shared.show(
                String(localized: "Dictation inserted — clipboard untouched."),
                style: .success
            )
            return
        }

        // Cancel any in-flight restore from a previous dictation —
        // back-to-back dictations shouldn't restore the previous-
        // previous clipboard on top of the current transcript.
        cancelPendingRestore()

        // 1. Snapshot existing pasteboard so we can put it back.
        //    Done BEFORE we write anything so we capture the user's
        //    actual prior state.
        let snapshot = captureClipboard()

        // 2. Write the transcript.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        let postWriteChangeCount = NSPasteboard.general.changeCount

        // 3. Try to auto-paste. If Accessibility permission is
        //    missing, fall back to the manual-paste toast.
        let didAutoPaste = attemptAutoPaste()
        // 4. Schedule restore. Auto-paste already landed → the transcript
        //    only needs to outlive the keystroke (quick restore, prior
        //    clipboard back in ~1.5 s). Manual-paste fallback → the
        //    transcript must stay around long enough to ⌘V by hand.
        let restoreAfter = didAutoPaste ? Self.quickRestoreSeconds : Self.retentionSeconds
        if didAutoPaste {
            ToastCenter.shared.show(
                String(localized: "Dictation pasted — your previous clipboard is coming right back."),
                style: .success
            )
        } else {
            ToastCenter.shared.show(
                String(localized: "Dictation copied — press ⌘V to paste. Clipboard reverts in \(Int(Self.retentionSeconds))s."),
                style: .success
            )
        }

        pendingSnapshot = ClipboardSnapshot(
            items: snapshot,
            changeCountAfterOurWrite: postWriteChangeCount
        )
        restoreTimer = Timer.scheduledTimer(
            withTimeInterval: restoreAfter,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreClipboardIfUnchanged()
            }
        }
    }

    /// Insert `text` at the caret of the system-wide focused UI element
    /// (replacing any selection) via the Accessibility API — no
    /// pasteboard involvement at all. Returns false when Accessibility
    /// isn't granted, no element has keyboard focus, or the element
    /// doesn't accept programmatic text insertion (many web views,
    /// secure fields) — callers then fall back to clipboard + ⌘V.
    private func attemptAXInsert(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return false }
        // AXUIElement is a CoreFoundation type — an unconditional
        // downcast from CFTypeRef is the sanctioned bridge.
        let element = focusedRef as! AXUIElement

        // Only proceed when the element explicitly supports setting the
        // selected text — writing blindly can beep or mangle state in
        // apps that expose the attribute read-only.
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else { return false }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if result == .success {
            log.info("Dictation inserted via AX — clipboard untouched")
            return true
        }
        return false
    }

    // MARK: - Auto-paste

    /// Synthesise a ⌘V keystroke against the current frontmost
    /// app. Returns `true` on success, `false` when Accessibility
    /// permission is denied (the keystroke would post to nowhere)
    /// or when CGEvent construction fails.
    ///
    /// Two-phase permission check:
    ///   1. Silent check via `AXIsProcessTrusted()` — no prompt.
    ///   2. Prompt only if step 1 returns false. The system
    ///      dialog appears AND we return false (permission
    ///      doesn't become true mid-call). Next dictation will
    ///      see step 1 succeed and auto-paste will work.
    ///
    /// First-dictation UX: the very first dictation pastes
    /// nothing because Accessibility wasn't granted yet, but the
    /// user now has the system dialog open and can grant. Second
    /// dictation works. The 10s clipboard hold means even the
    /// failed first attempt is recoverable via manual ⌘V.
    private func attemptAutoPaste() -> Bool {
        // Silent check first — avoids re-showing the system dialog
        // on every call when permission is granted.
        if !AXIsProcessTrusted() {
            // Permission missing — prompt once (system dedups the
            // dialog if user already saw it), but return false
            // because the dialog is non-modal and we'd be racing
            // against the user's click.
            let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options: NSDictionary = [promptOption: true]
            _ = AXIsProcessTrustedWithOptions(options)
            log.warning("Accessibility permission missing — prompted user, falling back to manual ⌘V for this dictation")
            return false
        }

        // Build a ⌘ down + V down + V up + ⌘ up sequence and post
        // it to the session-wide event tap. macOS dispatches it
        // to whichever app has frontmost focus.
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Couldn't create CGEventSource for paste keystroke")
            return false
        }

        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        let cmdKeyCode = CGKeyCode(kVK_Command)

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
            let vDown   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let vUp     = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        else {
            log.error("CGEvent construction returned nil")
            return false
        }

        // V events need the Command flag set so apps see them as
        // ⌘V (paste) rather than a plain "v" character.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Brief settle delay BEFORE posting — when the user
        // releases the hotkey, focus may not have fully resolved
        // to their text-field-of-choice yet (the OS posts our
        // keyUp event last, after which it can briefly re-rank
        // app activation). 80 ms is well below "noticeable lag"
        // (the eye misses anything under ~100 ms) but plenty
        // for the focus chain to settle.
        //
        // Empirically without this delay, pasting into Claude
        // desktop / Cursor / VS Code sometimes lands in the
        // wrong window (or nowhere) because they re-render
        // their input field state on focus-acquired.
        Thread.sleep(forTimeInterval: 0.08)

        // 2026-05-27 — bundleIdentifier is `.private`. Not strictly
        // PII but a precise fingerprint of which apps the user
        // dictates into; not something we want in the public unified
        // log stream long-term.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
        log.info("Posting ⌘V — frontmost app: \(frontmostBefore, privacy: .private)")

        let tap = CGEventTapLocation.cgSessionEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        return true
    }

    // MARK: - Snapshot + restore

    /// Capture every pasteboard type the user currently has so
    /// we can put it all back later. Covers plain text, RTF, file
    /// URLs, images, anything custom an app dropped on the
    /// pasteboard.
    private func captureClipboard() -> [[String: Data]] {
        guard let items = NSPasteboard.general.pasteboardItems else {
            return []
        }
        return items.map { item in
            var typeMap: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeMap[type.rawValue] = data
                }
            }
            return typeMap
        }
    }

    /// Put the captured items back on the pasteboard IF the user
    /// hasn't copied anything else in the meantime. The pasteboard
    /// changeCount monotonically increases on every write — we
    /// recorded the count right after writing the transcript, and
    /// if it's still that number now, nothing else has touched
    /// the pasteboard.
    private func restoreClipboardIfUnchanged() {
        defer {
            pendingSnapshot = nil
            restoreTimer = nil
        }
        guard let snapshot = pendingSnapshot else { return }
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != snapshot.changeCountAfterOurWrite {
            log.info("Pasteboard changed during retention window — skipping restore (\(currentCount, privacy: .public) vs \(snapshot.changeCountAfterOurWrite, privacy: .public))")
            return
        }
        NSPasteboard.general.clearContents()
        if snapshot.items.isEmpty {
            log.info("Restored empty pasteboard (no prior contents)")
            return
        }
        let nsItems: [NSPasteboardItem] = snapshot.items.map { typeMap in
            let item = NSPasteboardItem()
            for (typeString, data) in typeMap {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeString))
            }
            return item
        }
        NSPasteboard.general.writeObjects(nsItems)
        log.info("Restored pasteboard with \(nsItems.count, privacy: .public) item(s) after dictation grace window")
    }

    /// Cancel any pending restore — used when a NEW dictation
    /// happens before the previous one's 10 s window expired.
    /// The new transcript stays in clipboard, the new restore
    /// timer runs against the NEW snapshot.
    private func cancelPendingRestore() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        pendingSnapshot = nil
    }
}
