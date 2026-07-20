# Daisy colour system — Warm Graphite × Signal

This is the shared direction for the marketing site and the native app: calm,
warm graphite for the everyday UI; colour as a precise signal, not decoration.

## Core tokens

| Role | Value | Use |
| --- | --- | --- |
| Canvas | `#111210` | App/window background |
| Surface | `#171916` | Sidebars and quiet sections |
| Raised surface | `#1D201C` | Cards, menus and sheets |
| Hover surface | `#252923` | Hover and selected backgrounds |
| Subtle border | `#30342D` | Card and divider borders |
| Primary text | `#F5F3EC` | Titles and core controls |
| Secondary text | `#C9C7BD` | Body copy and labels |
| Tertiary text | `#9EA096` | Metadata only |
| Brand / idle centre | `#F6B74B` | Daisy centre and low-volume brand moments |
| Recording | `#FFB15C` | Only active microphone / audio activity |
| Technical / ready | `#70D6C2` | Links, focus rings, connected and ready states |
| Dictation | `#B7A2FF` | Dictation mode only |
| Voice note | `#FF9FB2` | Voice-note mode only |
| Error | `#FF9B93` | Destructive states only |

## Native-app application

- Use `Brand` for the Daisy flower's idle centre and `Recording` only while
  capturing audio. Do not use either as a general button fill.
- Use `Technical` for keyboard focus, connected providers, selected settings
  and a completed transcript. It is the cool counterpoint that makes the app
  feel precise while the graphite surfaces remain warm.
- Keep large surfaces neutral. Mode colour appears as the flower centre, a
  compact icon, waveform, or selected-tab indicator—never a whole panel.
- Primary buttons may use `Primary text` on graphite or a light fill with
  graphite label; reserve solid colour fills for actions that need immediate
  state recognition.
- Keep body text at 16pt or above where possible and maintain 4.5:1 contrast
  for text and interactive states. Do not communicate a state by colour alone.

## SwiftUI mapping

```swift
enum DaisyColor {
  static let canvas = Color(hex: "111210")
  static let surface = Color(hex: "171916")
  static let raisedSurface = Color(hex: "1D201C")
  static let hoverSurface = Color(hex: "252923")
  static let primaryText = Color(hex: "F5F3EC")
  static let secondaryText = Color(hex: "C9C7BD")
  static let tertiaryText = Color(hex: "9EA096")
  static let brand = Color(hex: "F6B74B")
  static let recording = Color(hex: "FFB15C")
  static let technical = Color(hex: "70D6C2")
  static let dictation = Color(hex: "B7A2FF")
  static let voiceNote = Color(hex: "FF9FB2")
  static let danger = Color(hex: "FF9B93")
}
```
