//
//  SoundEffects.swift
//  Daisy
//
//  Tiny audio cues for recording lifecycle events. Uses macOS
//  built-in `NSSound`-named system sounds so we don't have to
//  bundle audio assets — every macOS install since 10.0 ships the
//  same set under `/System/Library/Sounds/`. Apple has used these
//  same names since the System 7 era; they're effectively part of
//  the platform's vocabulary.
//
//  Selection is mode-aware on start. `Tink` originally signalled
//  "armed" for meeting starts but reads as a system-edge ping in
//  macOS UX (volume max, end-of-slider, unhandled key), which
//  made every hotkey tap feel like a mis-press. Replaced with
//  `Purr` for both meeting + dictation — a short, warm
//  "listening" tone. Voice notes keep `Pop` so quick taps stay
//  audibly distinct from the longer recording modes; we'll align
//  on Purr there too if the difference doesn't earn its keep.
//
//  Selection:
//   • Start (meeting)    → "Purr"   — short, warm, "listening"
//   • Start (voice note) → "Pop"    — soft accent, neutral
//   • Start (dictation)  → "Purr"   — same as meeting-start
//   • Pause              → "Pop"    — soft accent, neutral
//   • Resume             → "Purr"   — logically same as start
//   • Stop               → "Glass"  — clear, complete, finished
//
//  Volume: each NSSound starts at 1.0; we set 0.4 to keep cues
//  noticeable but not jarring. Recording-app sounds that boom
//  through office speakers are a usability hazard.
//
//  All entry points respect `AppSettings.recordingSoundsEnabled`
//  via the call sites in `RecordingSession`; this file just
//  plays — it doesn't gate.
//

import AppKit

@MainActor
enum SoundEffects {
    static func playStart(for mode: RecordingSession.RecordingMode = .meeting) {
        switch mode {
        case .meeting:   play(named: "Purr", fallback: "Pop")
        case .voiceNote: play(named: "Pop")
        case .dictation: play(named: "Purr", fallback: "Pop")
        }
    }
    static func playPause()   { play(named: "Pop") }
    static func playResume()  { play(named: "Purr", fallback: "Pop") }
    static func playStop()    { play(named: "Glass") }

    private static func play(named name: String, fallback: String? = nil) {
        // `NSSound(named:)` returns nil for unknown names — keep
        // the silent fallback rather than crashing if Apple ever
        // renames a system sound. `Purr` isn't on every macOS 14
        // build, so dictation passes a `fallback` ("Pop") rather
        // than silently doing nothing on those installs.
        if let sound = NSSound(named: name) {
            sound.volume = 0.4
            sound.play()
            return
        }
        if let fallback, let sound = NSSound(named: fallback) {
            sound.volume = 0.4
            sound.play()
        }
    }
}
