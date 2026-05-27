# Apple Feedback Assistant — draft

> Copy / paste into Feedback Assistant → macOS → ScreenCaptureKit category.
> Attach a sysdiagnose taken right after reproducing.

---

## Title

macOS 26.0.1 — `SCStream` with `capturesAudio = true` attaches without exception but delivers zero audio sample buffers on built-in output

## Steps to Reproduce

1. macOS 26.0.1 (build 25A362), M-series Mac
2. Built-in speakers + microphone (no Bluetooth, no virtual audio devices in Audio MIDI Setup, no Audio Hijack-style interceptors)
3. All TCC permissions granted (Microphone, Screen Recording, Accessibility)
4. Standard ScreenCaptureKit audio capture, audio-only style:

   ```swift
   let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
   let display = content.displays.first!
   let ourApps = content.applications.filter {
       Bundle.main.bundleIdentifier == $0.bundleIdentifier
   }
   let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])

   let config = SCStreamConfiguration()
   config.capturesAudio = true
   config.sampleRate = 48_000
   config.channelCount = 2
   config.excludesCurrentProcessAudio = true
   // Minimal video frame because SCStream requires a video output.
   config.width = 2
   config.height = 2
   config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
   config.showsCursor = false

   let stream = SCStream(filter: filter, configuration: config, delegate: self)
   try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
   try await stream.startCapture()
   ```

5. Play audio through default output device (any web video, music player, system test sound — confirmed audible from speakers)
6. Wait 30 seconds

## Expected

Delegate's `stream(_:didOutputSampleBuffer:of:)` is invoked repeatedly with `outputType == .audio` while the output device emits audio.

## Actual

`SCStream.startCapture()` returns without throwing. No `SCStreamDelegate.stream(_:didStopWithError:)` callback ever fires (capture stays nominally healthy). But the `.audio` sample-buffer callback is never invoked. Zero audio frames received over multi-minute sessions. Video frames still arrive normally on the parallel `.screen` output if registered.

Verified via internal silent-stream watchdog that fires after N seconds with `hasReceivedAudio == false`.

## Regression / Where it works

- ✅ macOS 14.x — same code path, same configuration, audio frames flow normally. Years of production use in our app (Daisy, app.essazanov.Daisy, signed + notarized Developer ID, Apple Silicon).
- ✅ macOS 15.x — same code path works.
- ❌ macOS 26.0.1 (25A362) — silent.

## Environment

- macOS: 26.0.1 (25A362)
- Hardware: MacBook Air (M-series), Apple Silicon
- Output device at time of repro: built-in MacBook speakers (confirmed playing audible audio)
- Input device: built-in MacBook microphone
- Bluetooth: none active
- Virtual audio: none installed (Audio MIDI Setup shows only built-in devices)
- TCC permissions: all granted (Microphone, Screen Recording, Accessibility)
- App: Developer ID signed, hardened runtime, notarized, sandbox off
- ScreenCaptureKit entitlements present

## Suspected workaround under test

- Drop `config.channelCount` to `1` (mono)
- Remove `config.excludesCurrentProcessAudio = true` (leave at default `false`)

Both changes applied behind `if #available(macOS 26.0, *)` in shipped 1.0.6.11 build of our app to see whether either knob restores buffer delivery for affected users. Will follow up here with results.

## Logs / Console output

Filter: `subsystem:app.essazanov.Daisy`

```
2026-05-23 13:21:02.384879+0800 0x1998 Info  Daisy: [SilenceMonitor] Silence monitor armed
2026-05-23 13:21:32.330878+0800 0x1998 Error Daisy: [SystemAudio] Silent SCStream detected after 30s (hasReceivedAudio=false)
2026-05-23 13:22:41.717966+0800 0x1998 Info  Daisy: [AudioRecorder] AudioRecorder stopped after 99.000351s
2026-05-23 13:22:41.753876+0800 0x1998 Error Daisy: [Session] Session ended with empty system audio despite captureSystemAudio=on
```

(Note: no `SCStream.didStopWithError` callback, no Bluetooth detection warning, no exception from `startCapture()`. Capture is nominally healthy but completely silent on `.audio` output.)

## Impact

User-facing: meeting recordings on macOS 26.0.1 lose the "other side" of every meeting. Per-speaker diarization collapses to a single track (microphone) and every transcript line gets labeled with the user's own display name, since the microphone is the only audio source.

Affects every macOS 26.0.x user of our app (Daisy, ~tester-scale right now, public Product Hunt launch scheduled for 2 June 2026 will significantly broaden exposure).
