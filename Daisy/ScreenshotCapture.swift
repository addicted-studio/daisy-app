//
//  ScreenshotCapture.swift
//  Daisy
//
//  Periodic screen capture via SCScreenshotManager. Writes PNGs into the
//  session folder so the markdown export can reference them inline.
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
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Screenshots")

    /// Begin periodic capture every `intervalSec` seconds. Writes files
    /// numbered `001.png`, `002.png`, … into the given directory.
    func start(intervalSec: Int, into directory: URL) async {
        guard intervalSec > 0 else { return }
        outputDir = directory
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

    private func captureOne() async {
        guard let dir = outputDir else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else { return }

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

            screenshotURLs.append(url)
            index += 1
        } catch {
            log.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}
