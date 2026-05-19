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
//  Selection:
//   • Start  → "Tink"      — a light tap, signals "armed"
//   • Pause  → "Pop"       — soft accent, neutral
//   • Resume → "Tink"      — same as start; the cue means "active"
//   • Stop   → "Glass"     — clear, complete, finished
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
    static func playStart()   { play(named: "Tink") }
    static func playPause()   { play(named: "Pop") }
    static func playResume()  { play(named: "Tink") }
    static func playStop()    { play(named: "Glass") }

    private static func play(named name: String) {
        // `NSSound(named:)` returns nil for unknown names — keep
        // the silent fallback rather than crashing if Apple ever
        // renames a system sound.
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.4
        sound.play()
    }
}
