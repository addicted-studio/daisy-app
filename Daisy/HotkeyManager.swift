//
//  HotkeyManager.swift
//  Daisy
//
//  Global hotkey for start / stop recording. Uses Carbon's
//  `RegisterEventHotKey` — modern Swift has no first-party replacement,
//  and Carbon hotkeys work without requiring Accessibility / Input
//  Monitoring permissions (unlike `CGEventTap` / `NSEvent` global
//  monitors). The trade-off is a small amount of `@convention(c)`
//  glue to bridge the system callback back into Swift.
//
//  Usage:
//      HotkeyManager.shared.register(choice: .ctrlOptCmdR) {
//          Task { await session.toggleByHotkey() }
//      }
//
//  Call `unregister()` to disable. Calling `register` again replaces
//  any previous registration.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import os

// MARK: - HotkeyChoice (struct, supports presets + custom)

/// A keyboard shortcut. Used to be a fixed enum of presets; now a
/// struct so users can record any combination via Settings →
/// HotkeyRecorder.
///
/// `keyCode == nil` means "disabled" (no global shortcut registered).
struct HotkeyChoice: Hashable, Codable, Sendable, Identifiable {
    /// Carbon virtual keycode (`kVK_*` from `HIToolbox.Events`).
    /// `nil` for `.none` (disabled).
    let keyCode: UInt32?
    /// Carbon modifier flags bitmask. `0` is legal (e.g. F-keys).
    let modifiers: UInt32?
    /// Human-readable string like "⌃⌥⌘R" — used as picker label and
    /// `id`. For custom combos this is computed from keyCode + mods.
    let label: String

    var id: String { label }

    // MARK: Presets

    static let none = HotkeyChoice(keyCode: nil, modifiers: nil, label: "Disabled")
    static let ctrlOptCmdR = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘R"
    )
    static let ctrlOptCmdD = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘D"
    )
    static let ctrlOptSpace = HotkeyChoice(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥Space"
    )
    static let shiftCmdR = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(shiftKey | cmdKey),
        label: "⇧⌘R"
    )
    static let f5 = HotkeyChoice(
        keyCode: UInt32(kVK_F5),
        modifiers: 0,
        label: "F5"
    )

    /// Preset list shown in Settings picker. Custom recorder lives
    /// alongside — see `HotkeyRecorder` view.
    static let allPresets: [HotkeyChoice] = [.none, .ctrlOptCmdR, .ctrlOptCmdD, .ctrlOptSpace, .shiftCmdR, .f5]

    /// Whether this choice is one of the canonical presets above.
    /// UI uses this to mark presets in the menu (vs custom recordings).
    var isPreset: Bool {
        Self.allPresets.contains(self)
    }

    // MARK: Custom recording

    /// Build a HotkeyChoice from an NSEvent.keyDown event. Used by
    /// HotkeyRecorder to convert captured keys into a choice. Returns
    /// nil if the event has no modifiers (a bare letter as a global
    /// hotkey would hijack typing).
    static func fromNSEvent(_ event: NSEvent) -> HotkeyChoice? {
        let carbonKey = UInt32(event.keyCode)
        let carbonMods = nsToCarbonModifiers(event.modifierFlags)
        // Require at least one non-shift modifier — otherwise the
        // global hotkey would steal every keystroke from every app.
        let strongMods: UInt32 = UInt32(cmdKey | controlKey | optionKey)
        if carbonMods & strongMods == 0 { return nil }
        let label = humanLabel(keyCode: carbonKey, modifiers: carbonMods)
        return HotkeyChoice(keyCode: carbonKey, modifiers: carbonMods, label: label)
    }

    /// NSEvent.ModifierFlags → Carbon modifier bitmask.
    private static func nsToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Compose a "⌃⌥⌘R"-style display label from key + modifiers.
    private static func humanLabel(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    /// Map a Carbon keyCode to its on-screen glyph. Falls back to
    /// `<keyCode>` for keys we haven't mapped.
    private static func keyName(for code: UInt32) -> String {
        // Punctuation + named keys
        switch Int(code) {
        case kVK_Space:     return "Space"
        case kVK_Return:    return "⏎"
        case kVK_Tab:       return "⇥"
        case kVK_Escape:    return "⎋"
        case kVK_Delete:    return "⌫"
        case kVK_F1:        return "F1"
        case kVK_F2:        return "F2"
        case kVK_F3:        return "F3"
        case kVK_F4:        return "F4"
        case kVK_F5:        return "F5"
        case kVK_F6:        return "F6"
        case kVK_F7:        return "F7"
        case kVK_F8:        return "F8"
        case kVK_F9:        return "F9"
        case kVK_F10:       return "F10"
        case kVK_F11:       return "F11"
        case kVK_F12:       return "F12"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default: break
        }
        // ANSI letters/digits
        let ansiMap: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_Grave: "`",
        ]
        return ansiMap[Int(code)] ?? "<\(code)>"
    }
}

// MARK: - Manager

/// Thread-safe storage for the registered hotkey action. The Carbon
/// `@convention(c)` callback runs outside any Swift actor and needs
/// to read the action without crossing MainActor's isolation barrier
/// — we keep it behind a lock and store it pre-typed as `@MainActor`
/// so the only legal invocation site is a MainActor hop.
///
/// `nonisolated` on the class makes init + set/get callable from any
/// context. Without this, the project-wide default actor isolation
/// (@MainActor for this target) would make the synthesised init
/// MainActor-only, and the `nonisolated let actionBox = ...`
/// property initializer below would fail to compile.
nonisolated private final class HotkeyActionBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(initialState: nil)

    func set(_ action: (@MainActor @Sendable () -> Void)?) {
        lock.withLock { $0 = action }
    }

    func get() -> (@MainActor @Sendable () -> Void)? {
        lock.withLock { $0 }
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// `nonisolated` so the C callback can reach it via the manager
    /// pointer without crossing MainActor isolation. The box itself
    /// is thread-safe; the action it stores is `@MainActor`-typed so
    /// it can only be called after hopping back onto the main actor.
    nonisolated fileprivate let actionBox = HotkeyActionBox()

    private init() {}

    /// Register a global hotkey. Replaces any previously-registered
    /// hotkey. Passing `.none` simply unregisters.
    func register(choice: HotkeyChoice, action: @escaping @MainActor @Sendable () -> Void) {
        unregister()
        guard let keyCode = choice.keyCode, let mods = choice.modifiers else { return }
        actionBox.set(action)

        // Install the dispatcher event handler once per registration so
        // we can capture the per-action closure.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // `actionBox` is nonisolated, so reading the action from
                // the C-callback context is legal. The action itself is
                // `@MainActor`-typed, so we MUST hop before invoking —
                // the type system enforces this.
                if let action = manager.actionBox.get() {
                    Task { @MainActor in action() }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )

        var ref: EventHotKeyRef?
        // 'DAIS' four-cc — unique signature, doesn't collide with
        // other registered hotkeys on the system.
        let id = EventHotKeyID(
            signature: fourCharCode("DAIS"),
            id: 1
        )
        RegisterEventHotKey(
            keyCode,
            mods,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        actionBox.set(nil)
    }
}

// MARK: - FourCharCode helper

private func fourCharCode(_ string: String) -> OSType {
    var code: OSType = 0
    for char in string.unicodeScalars.prefix(4) {
        code = (code << 8) | (OSType(char.value) & 0xFF)
    }
    return code
}
