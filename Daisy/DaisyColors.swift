//
//  DaisyColors.swift
//  Daisy
//
//  Semantic color tokens. All app colors flow through this file so the
//  rebrand only changes here, not across every view. Each token has a
//  light + dark variant resolved at render time via the dynamic
//  NSColor provider.
//
//  Recording / mic-active colors are deliberately locked to Apple's
//  system orange (HIG `systemOrange`). macOS and iOS use the same hue
//  for the Control Center "microphone in use" dot — Daisy inherits
//  that learned affordance instead of fighting it.
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
    // System orange. Locked. This is the *same* hue macOS / iOS use for
    // the Control Center mic-in-use indicator. The user sees orange and
    // already knows "something is listening" — Daisy plugs into that.

    /// Primary "recording in progress" color. Center of the petal widget,
    /// Stop button background, the recording status dot.
    static let daisyRecording = Color(
        light: Color(hex: 0xFF9500),  // Apple HIG systemOrange (Light)
        dark:  Color(hex: 0xFF9F0A)   // Apple HIG systemOrange (Dark)
    )

    /// Softer orange used for halos / glows around the recording center.
    static let daisyRecordingPulse = Color(
        light: Color(hex: 0xFFB04D),
        dark:  Color(hex: 0xFFC266)
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
        light: Color(hex: 0x9A6FE0),
        dark:  Color(hex: 0xB48BF2)
    )

    /// Halo / glow companion to `daisyDictation`.
    static let daisyDictationPulse = Color(
        light: Color(hex: 0xB9A4DC),
        dark:  Color(hex: 0xC9B6E8)
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
        light: Color(hex: 0xEE8593),
        dark:  Color(hex: 0xF49DAA)
    )

    /// Halo / glow companion to `daisyVoiceNote`.
    static let daisyVoiceNotePulse = Color(
        light: Color(hex: 0xF2A0AC),
        dark:  Color(hex: 0xF5B5BE)
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

    /// Main app background. Warm cream in light; deep warm-black in dark.
    /// Cream + dark-warm is chosen so the recording orange reads as the
    /// only saturated point on screen.
    static let daisyBgPrimary = Color(
        light: Color(hex: 0xFAF7F0),
        dark:  Color(hex: 0x1C1A17)
    )

    /// Sidebar / inset background — one step warmer than primary.
    static let daisyBgSidebar = Color(
        light: Color(hex: 0xF2EDE2),
        dark:  Color(hex: 0x161412)
    )

    /// Elevated surfaces — cards, popovers, the menu-bar popover.
    static let daisyBgElevated = Color(
        light: Color(hex: 0xFFFFFF),
        dark:  Color(hex: 0x252220)
    )

    /// Subtle dividers between sections.
    static let daisyDivider = Color(
        light: Color(hex: 0xE8E2D4),
        dark:  Color(hex: 0x2E2A26)
    )

    // ─── Petal mark ───────────────────────────────────────────────────
    //
    // The flower in idle / finished state. Warm amber — distinct from
    // recording orange so the eye knows "this is decoration, not a
    // live signal". Recording state replaces the center with
    // `daisyRecording` so the contrast itself communicates state.

    /// Center disc of the petal mark when idle / finished.
    static let daisyCenterIdle = Color(
        light: Color(hex: 0xFFB84D),
        dark:  Color(hex: 0xFFA826)
    )

    /// Petal fill — ink that matches the text on each appearance.
    static let daisyPetal = Color(
        light: Color(hex: 0x1C1A17),
        dark:  Color(hex: 0xF2EDE2)
    )

    // ─── Text ─────────────────────────────────────────────────────────

    static let daisyTextPrimary = Color(
        light: Color(hex: 0x1C1A17),
        dark:  Color(hex: 0xF2EDE2)
    )

    static let daisyTextSecondary = Color(
        light: Color(hex: 0x5C544A),
        dark:  Color(hex: 0xA8A096)
    )

    static let daisyTextTertiary = Color(
        light: Color(hex: 0x8C8478),
        dark:  Color(hex: 0x6E6862)
    )

    // ─── Status semantics ─────────────────────────────────────────────

    /// Success / finished / transcript ready. Sage — calm, not alarming.
    static let daisySuccess = Color(
        light: Color(hex: 0x7BAE8E),
        dark:  Color(hex: 0x8FC4A2)
    )

    /// Warning / summarizing / pending. Warm gold — explicitly NOT
    /// orange so it doesn't get confused with the recording state.
    static let daisyWarning = Color(
        light: Color(hex: 0xD4A24C),
        dark:  Color(hex: 0xE0B05C)
    )

    /// Error. A red shifted toward magenta so it can't be mistaken for
    /// the recording orange even at a glance.
    static let daisyError = Color(
        light: Color(hex: 0xC44545),
        dark:  Color(hex: 0xE06060)
    )

    /// Selection / accent / primary CTA when NOT in recording state.
    /// Deliberately warm cinnamon — keeps the palette in the cream
    /// family but is unambiguously distinct from `daisyRecording`
    /// (saturated system orange) AND from `daisySuccess` (sage).
    /// Sage was the previous accent — pulled because it read as
    /// "Granola territory", which Daisy actively differentiates from.
    static let daisyAccent = Color(
        light: Color(hex: 0xA66E2A),   // deep cinnamon
        dark:  Color(hex: 0xD4A04E)    // brighter amber for dark mode
    )

    /// Softer cinnamon for system-tinted backgrounds — sidebar List
    /// selection, focus halos, anywhere the OS fills a whole element
    /// with the tint. Pulling `daisyAccent` here would look as
    /// "active" as `daisyRecording`, which we want to avoid:
    /// recording orange owns the urgent / live affordance, selection
    /// should feel like a warm presence, not a button.
    static let daisyAccentSoft = Color(
        light: Color(hex: 0xC9986D),   // caramel-tan
        dark:  Color(hex: 0xB89376)    // warm taupe
    )
}
