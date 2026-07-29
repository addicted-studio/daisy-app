//
//  ScreenshotCapture.swift
//  Daisy
//
//  Periodic screen capture via SCScreenshotManager. Writes PNGs into the
//  session folder so the markdown export can reference them inline.
//
//  Alongside the PNGs it writes `index.json` — filename → position on
//  the recording's timeline. The filenames alone (`001.png`, `002.png`)
//  carry only ORDER, and order times nothing: multiplying by the capture
//  interval breaks the moment a session is paused (capture stops, the
//  wall clock doesn't), and breaks again for anyone who changed the
//  interval since.
//
//  The offset is AUDIO CAPTURED, not wall-clock elapsed, because that is
//  what the transcript measures. A `[mm:ss]` marker there comes from
//  `TranscriptSegment.startedAt`, which the transcribers build as
//  `sessionStart + samplesSeen / sampleRate` — a pause synthesises no
//  samples, so media time freezes while `Date()` keeps running. Stamping
//  screenshots with a `Date` delta would leave every frame after a pause
//  later than the line spoken beside it, by exactly the paused duration.
//  `RecordingSession.elapsed` is the same clock, so the two agree.
//

import Foundation
import ScreenCaptureKit
import AppKit
import Observation
import os

@Observable
@MainActor
final class ScreenshotCapture {
    private(set) var isRunning = false
    private(set) var screenshotURLs: [URL] = []
    private(set) var lastError: String?

    private var timer: Timer?
    private var outputDir: URL?
    private var index = 0
    /// Reads the recording's own clock — active recording time, pauses
    /// excluded. Supplied by `RecordingSession` rather than measured
    /// here, because the only clock worth stamping with is the one the
    /// transcript uses.
    private var elapsedProvider: (@MainActor () -> TimeInterval)?
    /// filename → position on the recording's timeline, in seconds.
    /// Rewritten whole on each capture: it is a few dozen entries, and a
    /// full atomic write costs nothing next to a screen grab while
    /// surviving a crash with at most the last frame missing.
    private var offsets: [String: Double] = [:]
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Screenshots")

    /// Display captured on the previous tick — only used to log
    /// display switches once instead of every 60 s.
    private var lastPickedDisplayID: CGDirectDisplayID?

    /// Begin periodic capture every `intervalSec` seconds. Writes files
    /// numbered `001.png`, `002.png`, … into the given directory.
    /// - Parameter elapsed: media time of the recording, in seconds.
    ///   Pass `RecordingSession.elapsed`; see the file header for why a
    ///   `Date` delta is the wrong clock. Note this is the MIC
    ///   recorder's measure, so a session whose microphone never
    ///   delivered frames stamps zeros — deliberately. That session's
    ///   transcript has no `[mm:ss]` progression either, so a wall-clock
    ///   fallback wouldn't be a second-best clock, it would be timecodes
    ///   aligned to nothing, stated with full confidence. Zeros are
    ///   visibly broken; plausible numbers are not.
    func start(
        intervalSec: Int,
        elapsed: @escaping @MainActor () -> TimeInterval,
        into directory: URL
    ) async {
        guard intervalSec > 0 else { return }
        outputDir = directory
        elapsedProvider = elapsed
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Resume-safe: pause→resume calls start() again on the SAME
        // directory. Continue numbering after any existing NNN.png instead
        // of resetting to 0 and overwriting the earlier screenshots (which
        // broke the OCR chronology). A fresh session's dir is empty → 0.
        let existing = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        screenshotURLs = existing
        // Next filename = (highest existing number) + 1, via %03d(index+1).
        index = existing.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.max() ?? 0
        // Resume path: keep the offsets already on disk. Recomputing
        // them now would date every pre-pause frame to the resume.
        offsets = ScreenshotIndex.load(from: directory)

        // Take one right away, then schedule.
        await captureOne()

        timer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(intervalSec),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.captureOne()
            }
        }
        isRunning = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Display to capture this tick. Prefers the display hosting the
    /// meeting app's window (issue #6 — the call is often on a
    /// secondary monitor, and `displays.first` isn't even guaranteed
    /// to be the main display); falls back to the main display, then
    /// to the first. Because `captureOne` re-enumerates
    /// `SCShareableContent` on every tick, dragging the meeting window
    /// to another monitor is picked up automatically on the next shot
    /// — no move-observer needed.
    ///
    /// Browser-tab meetings (Meet in Chrome/Safari) can't be matched —
    /// the owning app is just the browser — so they use the fallback,
    /// same as today's behaviour.
    private func pickDisplay(from content: SCShareableContent) -> SCDisplay? {
        // 1. Biggest on-screen window owned by a known meeting app.
        //    Size gate skips join-panels, HUDs and toolbars; the main
        //    call window (the one rendering shared content) is large.
        // Hoisted: `meetingBundleIDs()` decodes the user's additions
        // from UserDefaults, and there can be hundreds of windows.
        let meetingApps = MeetingDetector.meetingBundleIDs()
        let meetingWindows = content.windows.filter { w in
            guard let bid = w.owningApplication?.bundleIdentifier else { return false }
            return meetingApps.contains(bid)
                && w.isOnScreen
                && w.frame.width >= 300 && w.frame.height >= 200
        }
        if let win = meetingWindows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) {
            // SCWindow.frame and SCDisplay.frame share the same global
            // display-space coordinates — a plain contains() works.
            let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
            if let hit = content.displays.first(where: { $0.frame.contains(center) }) {
                if hit.displayID != lastPickedDisplayID {
                    lastPickedDisplayID = hit.displayID
                    let owner = win.owningApplication?.bundleIdentifier ?? "?"
                    log.info("Screenshot display → \(hit.displayID, privacy: .public) (meeting window: \(owner, privacy: .public))")
                }
                return hit
            }
        }

        // 2. No meeting window found — main display, then first.
        let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        let fallback = mainDisplay ?? content.displays.first
        if let picked = fallback, picked.displayID != lastPickedDisplayID {
            lastPickedDisplayID = picked.displayID
            let label = mainDisplay != nil ? "main display" : "first display"
            log.info("Screenshot display → \(picked.displayID, privacy: .public) (fallback: \(label, privacy: .public))")
        }
        return fallback
    }

    private func captureOne() async {
        guard let dir = outputDir else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = pickDisplay(from: content) else { return }

            // Exclude our own popover from the shot.
            let ourApps = content.applications.filter {
                Bundle.main.bundleIdentifier == $0.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ourApps,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.capturesAudio = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            // Save as PNG.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                lastError = "Could not encode screenshot."
                return
            }

            let filename = String(format: "%03d.png", index + 1)
            let url = dir.appendingPathComponent(filename)
            try png.write(to: url)

            // Past the `try` above, so the file is on disk before it
            // gets an index entry — no orphan pointing at nothing.
            if let elapsedProvider {
                offsets[filename] = max(0, elapsedProvider())
                ScreenshotIndex.write(offsets, to: dir)
            }

            screenshotURLs.append(url)
            index += 1
        } catch {
            log.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}

// MARK: - Timeline index

/// `screenshots/index.json` — filename → position on the recording's
/// timeline, in seconds of audio captured (the transcript's clock, not
/// the wall clock; see this file's header).
///
/// Deliberately a sidecar rather than a filename convention or EXIF: the
/// PNGs are an exported artifact people copy into Obsidian vaults and
/// mail to each other, and renaming them to carry a timestamp would break
/// every existing link. A sibling JSON file is ignorable by everything
/// that doesn't want it — including `ScreenTextExtractor` and
/// `SessionStore`, which both filter the folder to `.png`.
///
/// Sessions recorded before this existed have no index, and there is no
/// way to reconstruct one: the capture interval is a global setting that
/// may have changed since, and a paused session breaks the arithmetic
/// anyway. Those sessions show no timestamps, which is the honest
/// outcome — a plausible wrong time is worse than none.
nonisolated enum ScreenshotIndex {
    static let filename = "index.json"

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// `screenshots/highlights.json` — the frames OCR dedup judged to be
    /// a NEW screen rather than the same one again. Written once at
    /// finalize; absent when nothing legible was captured (a video call
    /// grid, a demo video), in which case callers walk every frame.
    static let highlightsFilename = "highlights.json"

    static func highlightsURL(in directory: URL) -> URL {
        directory.appendingPathComponent(highlightsFilename)
    }

    static func loadHighlights(from directory: URL) -> [String] {
        guard let data = try? Data(contentsOf: highlightsURL(in: directory)),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    static func writeHighlights(_ frames: [String], to directory: URL) {
        guard !frames.isEmpty, let data = try? JSONEncoder().encode(frames) else { return }
        try? data.write(to: highlightsURL(in: directory), options: .atomic)
    }

    static func load(from directory: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func write(_ offsets: [String: Double], to directory: URL) {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? data.write(to: url(in: directory), options: .atomic)
    }

    /// `12:04` for a screenshot URL — directly comparable to a
    /// `[mm:ss]` marker in the transcript. Nil when this session
    /// predates the index, or the frame somehow isn't in it.
    static func timecode(for screenshot: URL, offsets: [String: Double]) -> String? {
        guard let seconds = offsets[screenshot.lastPathComponent] else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
