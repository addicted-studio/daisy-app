//
//  DaisyColors.swift
//  Daisy
//
//  Semantic color tokens. All app colors flow through this file so the
//  rebrand only changes here, not across every view. Each token has a
//  light + dark variant resolved at render time via the dynamic
//  NSColor provider.
//
//  Daisy's warm amber signal echoes the familiar macOS recording cue and
//  the flower's yellow-orange centre. It is reserved for live capture.
//

import SwiftUI
import AppKit

// MARK: - Dynamic Color helpers

extension Color {
    /// Resolves to `light` in light mode and `dark` in dark mode at render time.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    /// `Color(hex: 0xFF9500)` — RGB hex literal initializer.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex         & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Daisy palette

extension Color {

    // ─── Recording / mic-active ───────────────────────────────────────
    //
    // Amber recording signal. This is the sole vivid, always-live colour.

    /// Primary "recording in progress" color. Center of the petal widget,
    /// Stop button background, the recording status dot.
    static let daisyRecording = Color(
        light: Color(hex: 0xF47B20),
        dark:  Color(hex: 0xFF9147)
    )

    /// Softer orange used for halos / glows around the recording center.
    static let daisyRecordingPulse = Color(
        light: Color(hex: 0xF8B36F),
        dark:  Color(hex: 0xFFD3A7)
    )

    // ─── Dictation mode (lilac) ───────────────────────────────────────
    //
    // Vivid lilac. Center of the petal widget when dictation is the
    // active recording mode. Lives on the SAME volume / saturation as
    // the recording orange — dictation IS live capture, just routed
    // to ⌘V instead of a transcript file, so its indicator must read
    // as "ON", not as a brand accent. Hue pulled slightly off true
    // blue-violet (≈265°) so it doesn't snap to "screen blue" and
    // stays in conversation with the warm-cream surfaces.

    static let daisyDictation = Color(
        // Vivid, bright lilac. 2026-05-31: first lifted toward systemOrange's
        // L* + warmed toward heather for iso-luminance across the three
        // recording modes — but that desaturated it into a pale wash that
        // blended into the warm-cream background (Egor, live build). Pulled
        // back to a SATURATED + brighter violet so it pops as a clear "ON"
        // signal on both the dark widget puck and the cream surfaces, while
        // still reading near the orange/coral siblings in weight.
        // History: original 0x8A6BC9/0xA98EE0 → pale 0xA98AD4/0xC0A8E6 → this.
        light: Color(hex: 0xB7A2FF),
        dark:  Color(hex: 0xC9B9FF)
    )

    /// Halo / glow companion to `daisyDictation`.
    static let daisyDictationPulse = Color(
        light: Color(hex: 0xD7CEFA),
        dark:  Color(hex: 0xE4DDFF)
    )

    // ─── Voice-note mode (coral) ──────────────────────────────────────
    //
    // Pink-coral. Center of the petal widget when capturing a voice
    // note. Deliberately pushed off the orange axis (hue ≈351°)
    // rather than the warm persimmon coral that sits adjacent to
    // recording orange — at peripheral-vision distance the eye must
    // read meetings vs voice-notes as two different dots, not as
    // "bright orange" vs "dim orange". Saturation pulled down to
    // ~55% so it stays a calm presence, not a cosmetic-pink shout.

    static let daisyVoiceNote = Color(
        // 2026-05-31 — lifted toward systemOrange's L* (was light 0xE86A7C
        // L*≈62 / dark 0xF08495) so meetings / voice-note / dictation sit
        // at matched visual weight — none reads as "more important". Hue +
        // ~55% saturation intent unchanged. ⚠️ EYEBALL on device.
        light: Color(hex: 0xD8755C),
        dark:  Color(hex: 0xEC9A84)
    )

    /// Halo / glow companion to `daisyVoiceNote`.
    static let daisyVoiceNotePulse = Color(
        light: Color(hex: 0xE8A493),
        dark:  Color(hex: 0xF5C0B3)
    )

    /// Paused state. Cool neutral gray so the widget reads as
    /// "held / not live" without borrowing any of the warm
    /// recording-family hues. Deliberately distinct from idle (cool
    /// white), recording (system orange), and finished (white).
    static let daisyPaused = Color(
        light: Color(hex: 0x9AA0A6),  // cool slate gray
        dark:  Color(hex: 0x7D828B)
    )

    // ─── Brand / surfaces ─────────────────────────────────────────────

    /// Main app background. Airy warm white in light; espresso in dark.
    /// The low-chroma surfaces leave the amber recording state unambiguous.
    static let daisyBgPrimary = Color(
        light: Color(hex: 0xFFFEFC),
        dark:  Color(hex: 0x0D100E)
    )

    /// Shared light-theme surface for the sidebar, cards and widgets.
    /// Keeping these surfaces identical makes the shell feel calm and unified.
    static let daisyBgSidebar = Color(
        light: Color(hex: 0xFBF9F5),
        dark:  Color(hex: 0x151816)
    )

    /// Elevated surfaces — cards, popovers, the menu-bar popover.
    /// Matches the sidebar in light mode by design.
    static let daisyBgElevated = Color(
        light: Color(hex: 0xFBF9F5),
        dark:  Color(hex: 0x151816)
    )

    /// Subtle dividers between sections.
    static let daisyDivider = Color(
        light: Color(hex: 0xECE7DE),
        dark:  Color(hex: 0x303531)
    )

    /// Sidebar navigation stays neutral. Icons and labels use a warm charcoal
    /// while the current destination receives a quiet, paper-light glow.
    static let daisySidebarInk = Color(
        light: Color(hex: 0x282824),
        dark:  Color(hex: 0xF4F5EF)
    )

    static let daisySidebarSelection = Color(
        light: Color(hex: 0xF0F1F0),
        dark:  Color(hex: 0x242825)
    )

    // ─── Petal mark ───────────────────────────────────────────────────
    //
    // The flower in idle / finished state. Golden-orange is calmer than the
    // vivid capture signal; recording replaces it with `daisyRecording`.

    /// Center disc of the petal mark when idle / finished.
    static let daisyCenterIdle = Color(
        light: Color(hex: 0xF5A14B),
        dark:  Color(hex: 0xF5A14B)
    )

    /// Warm, non-live accent for Home widgets and compact indicators.
    /// It echoes the flower centre without borrowing the vivid recording hue.
    static var daisyHomeAccent: Color { daisyCenterIdle }

    /// Petal fill — ink that matches the text on each appearance.
    static let daisyPetal = Color(
        light: Color(hex: 0x282824),
        dark:  Color(hex: 0xF4F5EF)
    )

    // ─── Text ─────────────────────────────────────────────────────────

    static let daisyTextPrimary = Color(
        light: Color(hex: 0x282824),
        dark:  Color(hex: 0xF4F5EF)
    )

    static let daisyTextSecondary = Color(
        light: Color(hex: 0x62625D),
        dark:  Color(hex: 0xBEC7BE)
    )

    static let daisyTextTertiary = Color(
        light: Color(hex: 0x85857F),
        dark:  Color(hex: 0x8F988E)
    )

    // ─── Status semantics ─────────────────────────────────────────────

    /// Success / finished / transcript ready. Sage — calm, not alarming.
    static let daisySuccess = Color(
        light: Color(hex: 0x3D7458),
        dark:  Color(hex: 0x93C9A5)
    )

    /// Warning / summarizing / pending. Warm gold — explicitly NOT
    /// orange so it doesn't get confused with the recording state.
    static let daisyWarning = Color(
        light: Color(hex: 0xF5A14B),
        dark:  Color(hex: 0xFFBF73)
    )

    /// Error. A red shifted toward magenta so it can't be mistaken for
    /// the recording orange even at a glance.
    static let daisyError = Color(
        light: Color(hex: 0xCF684E),
        dark:  Color(hex: 0xE98A73)
    )

    /// Brand accent / primary CTA when NOT in recording state.
    /// Warm amber owns general interaction; green stays semantic-only.
    static let daisyAccent = Color(
        light: Color(hex: 0xD97A28),
        dark:  Color(hex: 0xF5A14B)
    )

    /// Soft amber for selected backgrounds, focus halos, and controls.
    static let daisyAccentSoft = Color(
        light: Color(hex: 0xF8E5D2),
        dark:  Color(hex: 0x3A2A1E)
    )

    /// Ink for text/glyphs sitting ON an accent-filled surface —
    /// prominent buttons tinted daisyAccent/daisyHomeAccent, the
    /// active folder chip, the recording capsule. The system default
    /// (white) FAILS WCAG on the amber fills: ≈2.1:1 on 0xF5A14B
    /// (dark accent), ≈3.4:1 on 0xD97A28 (light accent). This warm
    /// near-black clears 4.5:1 on both, and on the recording orange.
    static let daisyTextOnAccent = Color(
        light: Color(hex: 0x2B1A07),
        dark:  Color(hex: 0x2B1A07)
    )

    // ─── Record button (idle / finished) ─────────────────────────────
    //
    // The "Start a recording" capsule fill when nothing is live: a warm
    // charcoal. Solid orange is reserved for a live microphone.
    static let daisyRecordIdle = Color(
        light: Color(hex: 0x242522),
        dark:  Color(hex: 0x334138)
    )
}
