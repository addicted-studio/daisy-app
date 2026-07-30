//
//  LayoutFixService.swift
//  Daisy
//
//  The fix key: press it and text typed in the wrong keyboard layout
//  becomes what you meant. «ghbdtn, rfr ltkf» → «привет, как дела».
//
//  Two sources of text, in order:
//
//   1. A selection, read through PasteboardProxy. Works in any app that
//      answers ⌘C, which is nearly all of them, and lets the user fix
//      something they typed an hour ago.
//   2. The word being typed right now — but only when the automatic
//      watcher is running, because it is the thing that already has that
//      word. This is the Punto Switcher habit (type, notice, hit the
//      key) and it costs us nothing extra: no Accessibility text
//      inspection, no per-app quirks, just the buffer the tap already
//      keeps.
//
//  With the watcher off and nothing selected, the honest answer is to
//  say so — which the toast does.
//

import AppKit
import ApplicationServices
import os

@MainActor
final class LayoutFixService {
    static let shared = LayoutFixService()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LayoutFix")
    /// A second press while the first is mid-flight would fight over the
    /// clipboard.
    private var isRunning = false

    private init() {}

    func trigger(settings: AppSettings) async {
        guard !isRunning else { return }

        guard KeyboardLayouts.shared.installed.count > 1 else {
            ToastCenter.shared.show(
                String(localized: "Add a second keyboard layout in System Settings — there's nothing to switch between."),
                style: .warning
            )
            return
        }
        // We synthesize ⌘C / ⌘V and backspaces.
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            ToastCenter.shared.show(
                String(localized: "Fixing the layout needs Accessibility access — grant it in System Settings and try again."),
                style: .warning
            )
            return
        }

        // Same exclusions as the automatic watcher: ⌘C / ⌘V into a
        // terminal or a spreadsheet cell is its own kind of damage, and
        // the reasons don't change because the user asked.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !LayoutAutoFix.isExcluded(frontmost) else {
            ToastCenter.shared.show(
                String(localized: "Daisy doesn't rewrite text in this app — it's on the excluded list."),
                style: .warning
            )
            return
        }

        isRunning = true
        defer { isRunning = false }

        // 1. A selection, if there is one.
        let borrow = PasteboardProxy.shared.borrow()
        if let selection = await PasteboardProxy.shared.copySelection(borrow) {
            guard let fix = LayoutFix.deliberate(selection) else {
                PasteboardProxy.shared.giveBack(borrow)
                ToastCenter.shared.show(
                    String(localized: "That already looks like the layout you meant."),
                    style: .info
                )
                return
            }
            PasteboardProxy.shared.pasteAndReturn(fix.text, borrow)
            finish(with: fix, settings: settings)
            return
        }
        PasteboardProxy.shared.giveBack(borrow)

        // 2. No selection — the word in flight, if anyone is watching.
        //    That path types the correction itself, switches the source
        //    and counts the fix, so there is nothing to finish here.
        if LayoutAutoFix.shared.fixWordInFlight() != nil { return }

        ToastCenter.shared.show(
            LayoutAutoFix.shared.isRunning
                ? String(localized: "Nothing to fix — select the text, or type a word first.")
                : String(localized: "Select the text you want fixed, then press the shortcut."),
            style: .warning
        )
    }

    /// Shared tail: switch the input source if asked, count the fix, and
    /// say what happened. Switching is the difference between fixing one
    /// word and fixing the sentence — without it the next word goes
    /// wrong the same way.
    private func finish(with fix: LayoutFix.Fix, settings: AppSettings) {
        if settings.layoutFixSwitchesSource {
            KeyboardLayouts.shared.select(fix.target)
        }
        UsageStats.shared.recordFixes(polished: 1)
        log.info("Layout fix → \(fix.target.id, privacy: .public)")
    }
}
