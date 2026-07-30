//
//  LayoutAutoFix.swift
//  Daisy
//
//  Fixing the wrong keyboard layout as you type, without being asked.
//  Off by default, and it should stay that way: everything below is a
//  negotiation between "useful" and "silently rewrote what someone
//  typed".
//
//  WHAT IT WATCHES. A LISTEN-ONLY event tap on key-down (plus mouse
//  clicks, to know the caret moved). Listen-only is not a detail: a tap
//  that can modify events can also drop them, and a bug in this file
//  would then mean keys that never arrive. This one cannot break typing
//  even if every line of it is wrong. It needs Input Monitoring to
//  listen and Accessibility to type the correction back.
//
//  WHAT IT NEVER DOES. Nothing is logged, stored, or sent: the buffer is
//  one word, in memory, cleared at every boundary, click, chord, app
//  switch, and while macOS reports secure input anywhere on the system.
//  Terminals, IDEs, remote desktops and password managers are excluded
//  outright — see `excludedBundleIDs` for why each one is there.
//
//  WHY IT REFUSES SO OFTEN. Deleting and retyping is destructive, and
//  the app is guessing about a text field it cannot see. Five things must
//  ALL hold before a single character is touched:
//
//    1. Accessibility says the focus is editable text. Letters typed
//       into a message list are type-select, not text — and backspaces
//       there delete mail. This check is the difference between a fixer
//       and a shredder.
//    2. Nothing was typed between the word finishing and this code
//       running. The decision happens a main-actor hop later, and on a
//       busy machine that hop is long enough to type two more words.
//    3. The characters in front of the caret are the ones we think we
//       typed — asked through Accessibility where the app will answer.
//       This is what catches macOS text replacement ("omw" → "On my
//       way!"), inline autocomplete, and auto-paired brackets.
//    4. The word is unknown to the spell checker as typed and a real
//       word converted (see LayoutFix).
//    5. Number of BACKSPACES equals number of KEY PRESSES, which is not
//       the same as the number of characters — one press can produce a
//       combining mark that merges into the previous grapheme.
//
//  THE ONE THING IT DELIBERATELY CANNOT DO: fix a word ended with Return
//  or Tab. Punto Switcher can, because it swallows the key, holds it,
//  decides, then re-sends. Ours arrives after the fact — and if the
//  Return already sent a chat message, deleting the word and retyping it
//  would send a SECOND message. A missed fix is an annoyance; a
//  duplicate message to a client is not. Those words are what the fix
//  key is for.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// The tap's C callback. A file-level function rather than a closure
/// property: it must convert to `@convention(c)`, and a top-level
/// `nonisolated` func is the spelling with no isolation-inference
/// question hanging over it.
private nonisolated func daisyLayoutTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .keyDown:
        LayoutAutoFix.handle(event)
    case .leftMouseDown, .rightMouseDown:
        // The caret may have moved anywhere; the word in flight is no
        // longer the word in front of it, and it is no longer a candidate
        // for the fix key either.
        LayoutAutoFix.buffer.discard()
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // macOS switches a tap off if it ever blocks. Ours is
        // listen-only so it can't, but a machine under real load can
        // still trip it. Everything typed while we were deaf is
        // unaccounted for, so the buffer goes with it.
        LayoutAutoFix.buffer.discard()
        Task { @MainActor in LayoutAutoFix.shared.reenable() }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class LayoutAutoFix {
    static let shared = LayoutAutoFix()

    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: (any NSObjectProtocol)?
    /// Read for `layoutFixSwitchesSource` only. Weak because settings
    /// outlive nothing here and a dangling reference must not keep the
    /// object alive; a missing one means "don't switch", the quieter of
    /// the two behaviours.
    private weak var settings: AppSettings?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LayoutAutoFix")

    /// The word being typed. Lives outside the actor because the event
    /// tap's C callback reaches it, and hopping to the main actor on
    /// every keystroke would put our latency inside the user's typing.
    nonisolated static let buffer = WordBuffer()

    /// How stale a just-finished word may be and still be fixable by the
    /// key. The hotkey's own key-down clears the buffer on its way past
    /// the tap, so without this the key would always find nothing.
    private static let recentWordWindow: TimeInterval = 3

    private init() {}

    // MARK: - Lifecycle

    func start(settings: AppSettings) {
        self.settings = settings
        guard !isRunning else { return }
        guard KeyboardLayouts.shared.installed.count > 1 else { return }

        // Input Monitoring — to hear the keys.
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            ToastCenter.shared.show(
                String(localized: "Automatic layout fixing needs Input Monitoring. Grant it in System Settings, then quit and reopen Daisy."),
                style: .warning
            )
            return
        }
        // Accessibility — to type the correction back, and to see whether
        // the focus is text at all.
        guard AXIsProcessTrusted() else {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            ToastCenter.shared.show(
                String(localized: "Automatic layout fixing needs Accessibility access — grant it in System Settings, then turn it on again."),
                style: .warning
            )
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: daisyLayoutTapCallback,
            userInfo: nil
        ) else {
            log.error("CGEvent.tapCreate returned nil — layout auto-fix not started")
            ToastCenter.shared.show(
                String(localized: "Couldn't start automatic layout fixing. Check Input Monitoring for Daisy in System Settings."),
                style: .error
            )
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        // A word half-typed in one app has nothing to do with the next.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in LayoutAutoFix.buffer.discard() }
        // Spin the spell-check service up now, not inside the first
        // keystroke that needs an answer.
        LayoutFix.warmUp()
        log.info("Layout auto-fix started")
    }

    func stop() {
        LayoutAutoFix.buffer.clear()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        tap = nil
        runLoopSource = nil
        activationObserver = nil
        guard isRunning else { return }
        isRunning = false
        log.info("Layout auto-fix stopped")
    }

    func apply(settings: AppSettings) {
        if settings.layoutFixAuto {
            start(settings: settings)
        } else {
            stop()
        }
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log.warning("Layout auto-fix tap was disabled by the system — re-enabled")
    }

    // MARK: - Reading the keyboard (off the main actor)

    nonisolated static func handle(_ event: CGEvent) {
        // Never analyse our own typing.
        guard !SyntheticEvents.isOurs(event) else { return }
        // A password field somewhere on the system: don't even buffer.
        guard !IsSecureEventInputEnabled() else {
            buffer.discard()
            return
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer.clear()   // a chord is a command, not a word
            return
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if caretMovingKeyCodes.contains(keyCode) {
            buffer.discard()
            return
        }
        if keyCode == UInt16(kVK_Delete) {
            // Backspacing inside a word is ordinary typing, so track it
            // instead of giving up — but a delete on an empty buffer
            // means we no longer know what is in front of the caret.
            if !buffer.deleteLast() { buffer.discard() }
            return
        }
        if keyCode == UInt16(kVK_ForwardDelete) {
            // Removes what is AFTER the caret — never anything we
            // buffered, so our picture of the field is now wrong.
            buffer.discard()
            return
        }

        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        guard length == 1, let scalar = Unicode.Scalar(units[0]) else {
            // No character (dead key, F-key, modifier alone) — we can't
            // account for what the app did with it.
            buffer.clear()
            return
        }
        let character = Character(scalar)
        if character.isLetter || character == "'" || character == "-" {
            buffer.append(character)
            return
        }
        // A boundary — the word just ended. Only for characters that
        // really are text: function keys and Help report private-use
        // scalars, and retyping one of those would insert garbage into
        // the document.
        let finished = buffer.take()
        guard isTextBoundary(character), let finished,
              finished.word.count >= LayoutFix.minAutomaticWordLength else { return }
        // Return and Tab may have submitted the text already — see the
        // file header for why those are left alone. Not even as a
        // candidate for the fix key: after a Return the caret is on the
        // next line (or in the next field), so the word is no longer in
        // front of it.
        guard !character.isNewline, character != "\t" else {
            buffer.discard()
            return
        }
        Task { @MainActor in
            LayoutAutoFix.shared.consider(finished, boundary: character)
        }
    }

    nonisolated private static func isTextBoundary(_ character: Character) -> Bool {
        character == " " || character.isNumber || character.isPunctuation || character.isSymbol
            || character.isNewline || character == "\t"
    }

    /// Keys after which we no longer know what sits in front of the
    /// caret: arrows, Home/End, Page up/down, Escape.
    nonisolated private static let caretMovingKeyCodes: Set<UInt16> = [
        UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
        UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown),
        UInt16(kVK_Escape),
    ]

    // MARK: - Deciding (on the main actor)

    private func consider(_ finished: WordBuffer.Word, boundary: Character) {
        // Cheapest first, and in this order on purpose: nearly every word
        // stops at `LayoutFix.automatic`, and the checks after it each
        // cost a round trip to another process.
        guard isRunning, contextAllows() else { return }
        // Anything typed since the boundary means the caret has moved on
        // and our arithmetic is stale. This is the common case on a busy
        // machine, not an exotic one.
        guard LayoutAutoFix.buffer.generation == finished.generation else { return }
        guard let fix = LayoutFix.automatic(word: finished.word) else { return }
        guard focusIsEditableText() else { return }

        // The boundary character is deleted and retyped with the word:
        // the field already has it, and deleting the word alone would
        // leave the space in the wrong place.
        let presses = finished.presses + 1
        let expected = finished.word + String(boundary)
        guard confirmBeforeCaret(expected) else { return }
        guard replaceInFlight(deleting: presses, typing: fix.text + String(boundary)) else { return }
        settle(fix)
        log.info("Auto-fixed a word into \(fix.target.id, privacy: .public)")
    }

    /// The fix key's second source: the word just typed. The user asked,
    /// so this uses `deliberate` (no dictionary needed) and leaves the
    /// boundary alone — there isn't one yet.
    func fixWordInFlight() -> LayoutFix.Fix? {
        guard isRunning, contextAllows() else { return nil }
        guard let candidate = LayoutAutoFix.buffer.wordInFlightOrJustFinished(
            within: Self.recentWordWindow
        ), candidate.word.count > 1 else { return nil }
        guard let fix = LayoutFix.deliberate(candidate.word) else { return nil }
        guard focusIsEditableText(), confirmBeforeCaret(candidate.word) else { return nil }
        guard replaceInFlight(deleting: candidate.presses, typing: fix.text) else { return nil }
        settle(fix)
        return fix
    }

    /// Conditions that have to hold at the moment of acting, not at the
    /// moment the feature was switched on.
    private func contextAllows() -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        // An input method (Japanese, Pinyin, Hangul) composes text from
        // keystrokes on its own; what we saw is not what landed.
        guard !KeyboardLayouts.shared.isInputMethodActive else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return !Self.isExcluded(frontmost)
    }

    /// The one check that keeps backspaces out of mail lists, Finder and
    /// single-key-shortcut web apps — where letters are commands and a
    /// Delete is not an edit but a deletion. Costs an Accessibility round
    /// trip, so it runs last.
    private func focusIsEditableText() -> Bool {
        AXFocus.kind() == .editable
    }

    /// Does the text in front of the caret actually end with what we
    /// believe we typed? Nil answers (an app that won't say) are allowed
    /// through — most apps outside AppKit won't answer, and refusing them
    /// all would leave the feature working nowhere. A WRONG answer is
    /// refused: that is text replacement or autocomplete having changed
    /// the field under us.
    private func confirmBeforeCaret(_ expected: String) -> Bool {
        let units = expected.utf16.count
        guard let actual = AXFocus.textBeforeCaret(count: units) else { return true }
        return actual == expected
    }

    private func settle(_ fix: LayoutFix.Fix) {
        // Our own typing is marked and skipped by the tap, so the buffer
        // would otherwise still hold the pre-fix word — and the fix key
        // must not be able to "fix" it a second time.
        LayoutAutoFix.buffer.discard()
        if settings?.layoutFixSwitchesSource ?? false {
            KeyboardLayouts.shared.select(fix.target)
        }
        UsageStats.shared.recordFixes(polished: 1)
    }

    // MARK: - Typing back

    /// Delete `count` key presses' worth of text and type `text`.
    /// Every event is built BEFORE any of them is posted: half of this
    /// operation — backspaces with no replacement — is the one outcome
    /// worse than not running at all.
    private func replaceInFlight(deleting count: Int, typing text: String) -> Bool {
        guard count > 0, count < 128 else { return false }
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }

        var events: [CGEvent] = []
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else { return false }
            events.append(down)
            events.append(up)
        }
        // Text goes on a key event rather than through key codes: the
        // correction is in the OTHER layout, so the codes that would
        // produce it are exactly what the active layout cannot type.
        guard let textDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let textUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        textDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        textUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        events.append(textDown)
        events.append(textUp)

        for event in events {
            // Flags cleared explicitly. A synthesized Delete that
            // inherits a physically-held Option is ⌥Delete — it deletes
            // a whole WORD per press, and this posts several.
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.marker)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    // MARK: - Exclusions

    /// Apps where deleting and retyping a word is worse than leaving the
    /// mistake, either because the text is not prose or because the app
    /// rewrites the line under us:
    ///
    ///   - terminals: a wrong "correction" is a command that runs;
    ///   - editors and IDEs: identifiers are misspelled by definition,
    ///     and autocomplete edits the same characters we are editing;
    ///   - password managers and Keychain: nobody's master password
    ///     should pass through a language check;
    ///   - remote desktops and VMs: the keystrokes belong to another
    ///     machine, and the caret is not where we think it is.
    nonisolated static func isExcluded(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return true }
        if excludedBundleIDs.contains(bundleID) { return true }
        return excludedPrefixes.contains { bundleID.hasPrefix($0) }
    }

    nonisolated private static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.apple.keychainaccess",
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",
        "com.teamviewer.TeamViewer",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
    ]

    nonisolated private static let excludedPrefixes: [String] = [
        "com.jetbrains.",       // IntelliJ, PyCharm, WebStorm, …
        "com.google.android.studio",
        "com.1password.",
        "com.agilebits.onepassword",
        "com.bitwarden.",
        "com.valvesoftware.steam",
    ]
}

/// The one word being typed, behind a lock so the event tap's callback
/// can reach it without a hop to the main actor.
///
/// Tracks KEY PRESSES as well as characters, because the number of
/// backspaces needed is the number of presses: a layout whose keys emit
/// combining marks can merge two presses into one `Character`, and
/// deleting by character count would leave a stray mark glued to the
/// correction.
///
/// `generation` counts every key-down the tap saw. Work that starts on
/// the main actor carries the generation it was decided at and refuses to
/// act if it has moved — the user kept typing while we were thinking.
nonisolated final class WordBuffer: @unchecked Sendable {
    struct Word: Sendable {
        let word: String
        let presses: Int
        let generation: UInt64
    }

    private struct State {
        var word = ""
        var presses = 0
        var generation: UInt64 = 0
        /// Last non-empty word and when it was cleared, in
        /// `DispatchTime` nanoseconds. The fix key needs this: the
        /// hotkey's own key-down reaches the tap first and clears the
        /// buffer, so by the time the hotkey handler runs the word is
        /// already gone.
        var recent: (word: String, presses: Int, at: UInt64)?
    }

    private static let maxPresses = 64
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var generation: UInt64 { lock.withLock { $0.generation } }

    func append(_ character: Character) {
        lock.withLock { state in
            state.generation &+= 1
            guard state.presses < Self.maxPresses else { return }
            state.word.append(character)
            state.presses += 1
        }
    }

    /// True if something was actually removed — false means the caret is
    /// somewhere we weren't tracking.
    func deleteLast() -> Bool {
        lock.withLock { state in
            state.generation &+= 1
            guard state.presses > 0, !state.word.isEmpty else { return false }
            state.word.removeLast()
            state.presses -= 1
            return true
        }
    }

    /// Forget the word, but keep it as the fix key's candidate — used
    /// where the keystroke means "not typing" rather than "the caret
    /// moved". The fix key's own chord lands here, which is the only
    /// reason the candidate exists.
    func clear() {
        lock.withLock { state in
            state.generation &+= 1
            stash(&state)
            state.word = ""
            state.presses = 0
        }
    }

    /// Forget the word AND the candidate — the caret is no longer behind
    /// what we were tracking, so retyping it later would eat something
    /// else.
    func discard() {
        lock.withLock { state in
            state.generation &+= 1
            state.word = ""
            state.presses = 0
            state.recent = nil
        }
    }

    /// Read and clear — the word is finished.
    func take() -> Word? {
        lock.withLock { state in
            state.generation &+= 1
            stash(&state)
            let finished = Word(word: state.word, presses: state.presses, generation: state.generation)
            state.word = ""
            state.presses = 0
            return finished.word.isEmpty ? nil : finished
        }
    }

    /// What the fix key should act on: the word being typed, or the one
    /// that was cleared moments ago (by the fix key's own keystroke).
    func wordInFlightOrJustFinished(within window: TimeInterval) -> Word? {
        lock.withLock { state in
            if !state.word.isEmpty {
                return Word(word: state.word, presses: state.presses, generation: state.generation)
            }
            guard let recent = state.recent else { return nil }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- recent.at) / 1_000_000_000
            guard elapsed <= window else { return nil }
            return Word(word: recent.word, presses: recent.presses, generation: state.generation)
        }
    }

    private func stash(_ state: inout State) {
        guard !state.word.isEmpty else { return }
        state.recent = (state.word, state.presses, DispatchTime.now().uptimeNanoseconds)
    }
}
