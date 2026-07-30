//
//  AXFocus.swift
//  Daisy
//
//  What has keyboard focus right now, asked through Accessibility.
//
//  This exists because of one question the layout fixer cannot answer
//  any other way: is it safe to send backspaces? Letters typed into a
//  MESSAGE LIST are type-select, not text — and the backspaces that
//  would fix a word there delete mail instead. Same shape in Finder, in
//  Gmail's keyboard shortcuts, in any app where a bare letter is a
//  command. A fixer that can't tell the difference is a text shredder
//  with good intentions.
//
//  Everything here is best-effort by design. Apps vary wildly in what
//  they expose (Electron and web views worst of all), and every failure
//  returns "don't know" — which callers must treat as "don't touch".
//
//  AX calls block on the target app, so the messaging timeout is pinned
//  short: this runs between a keystroke and the character appearing, and
//  an unresponsive app must cost us milliseconds, not seconds.
//

import AppKit
import ApplicationServices

@MainActor
enum AXFocus {

    enum Kind {
        /// Not a text field, or we couldn't tell. Never edit.
        case unknown
        /// A password field. Never edit, never inspect.
        case secure
        /// Editable text.
        case editable
    }

    private static let messagingTimeout: Float = 0.2

    static func kind() -> Kind {
        guard let element = focusedElement() else { return .unknown }
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return .secure }
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole {
            return .editable
        }
        // Web and Electron inputs often report something else entirely.
        // A settable value attribute is the next best evidence that this
        // is a place text can be edited.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
            return .unknown
        }
        return settable.boolValue ? .editable : .unknown
    }

    /// The `count` characters immediately before the caret, when the app
    /// will say. Used to CONFIRM that what we are about to delete is what
    /// we think it is — the difference between fixing a word and eating
    /// the sentence in front of it.
    ///
    /// Nil means "no answer", which is not the same as "doesn't match".
    static func textBeforeCaret(count: Int) -> String? {
        guard count > 0, let element = focusedElement() else { return nil }
        guard let caret = caretLocation(element), caret >= count else { return nil }
        var range = CFRange(location: caret - count, length: count)
        // Ask for just the tail if the app supports it — the whole value
        // of a long document is expensive and often refused.
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &result
            ) == .success, let text = result as? String {
                return text
            }
        }
        // Fall back to the whole value.
        guard let whole = string(element, kAXValueAttribute) else { return nil }
        let units = Array(whole.utf16)
        guard caret <= units.count, caret - count >= 0 else { return nil }
        return String(decoding: units[(caret - count)..<caret], as: UTF16.self)
    }

    // MARK: - Plumbing

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
        let value = focused,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Caret position in UTF-16 units, or nil when the app doesn't
    /// report a selection.
    private static func caretLocation(_ element: AXUIElement) -> Int? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        ) == .success,
        let value = raw,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        // A non-empty selection means the caret isn't sitting after a
        // word we typed — treat it as no answer.
        guard range.length == 0 else { return nil }
        return range.location
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }
}
