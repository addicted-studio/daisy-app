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

// MARK: - Choice enum

/// Preset hotkeys offered in Settings. A fixed list keeps v0.1 simple;
/// a future "custom recorder" can land later. Defaults to `.ctrlOptCmdR`
/// since `⌃⌥⌘R` is the macOS convention for global record actions.
enum HotkeyChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case ctrlOptCmdR
    case ctrlOptCmdD
    case ctrlOptSpace
    case shiftCmdR
    case f5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:         "Disabled"
        case .ctrlOptCmdR:  "⌃⌥⌘R"
        case .ctrlOptCmdD:  "⌃⌥⌘D"
        case .ctrlOptSpace: "⌃⌥Space"
        case .shiftCmdR:    "⇧⌘R"
        case .f5:           "F5"
        }
    }

    /// Carbon virtual keycode (`kVK_*` from `HIToolbox.Events`).
    fileprivate var keyCode: UInt32? {
        switch self {
        case .none:         nil
        case .ctrlOptCmdR:  UInt32(kVK_ANSI_R)
        case .ctrlOptCmdD:  UInt32(kVK_ANSI_D)
        case .ctrlOptSpace: UInt32(kVK_Space)
        case .shiftCmdR:    UInt32(kVK_ANSI_R)
        case .f5:           UInt32(kVK_F5)
        }
    }

    /// Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`,
    /// `shiftKey`).
    fileprivate var modifiers: UInt32? {
        switch self {
        case .none:         nil
        case .ctrlOptCmdR:  UInt32(controlKey | optionKey | cmdKey)
        case .ctrlOptCmdD:  UInt32(controlKey | optionKey | cmdKey)
        case .ctrlOptSpace: UInt32(controlKey | optionKey)
        case .shiftCmdR:    UInt32(shiftKey | cmdKey)
        case .f5:           0
        }
    }
}

// MARK: - Manager

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    /// Register a global hotkey. Replaces any previously-registered
    /// hotkey. Passing `.none` simply unregisters.
    func register(choice: HotkeyChoice, action: @escaping () -> Void) {
        unregister()
        guard let keyCode = choice.keyCode, let mods = choice.modifiers else { return }
        self.action = action

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
                // Hop onto the main actor — the action closure touches
                // RecordingSession + UI state, both MainActor-isolated.
                Task { @MainActor in manager.action?() }
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
        action = nil
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
