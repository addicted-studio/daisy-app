//
//  AudioInputDevices.swift
//  Daisy
//
//  CoreAudio facade for enumerating microphone-capable input devices
//  and resolving a user-saved selection back to an `AudioDeviceID`.
//
//  Why CoreAudio instead of AVFoundation:
//   • `AVCaptureDevice.devices(for: .audio)` exists but targets the
//     AVCaptureSession pipeline (camera/photo) and is awkward to wire
//     into AVAudioEngine.
//   • AVAudioEngine's `inputNode` is internally a HAL audio unit
//     (AUHAL) — to point it at a specific device we have to call
//     `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, …)`
//     with an `AudioDeviceID` anyway, so CoreAudio is the natural
//     source of truth.
//
//  Stability of identifiers:
//   • `AudioDeviceID` is a session-local UInt32 that can change when
//     devices are unplugged / replugged or after a reboot.
//   • `kAudioDevicePropertyDeviceUID` returns a CFString that is
//     stable across reboots and reconnects (e.g. for built-in mic
//     it's "BuiltInMicrophoneDevice"; for AirPods Pro it's the
//     pairing UID).
//   • We persist UID in `AppSettings.selectedMicDeviceUID` and
//     resolve it back to a fresh `AudioDeviceID` at every recording
//     start. If the saved device is gone (unplugged), we fall back
//     to system default.
//

import CoreAudio
import Foundation
import os

/// One input-capable audio device visible to the system.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnects. Persist this, not `id`.
    let uid: String
    /// Human-readable device name (e.g. "MacBook Pro Microphone",
    /// "AirPods Pro", "Shure MV7"). Surfaced in the Settings picker.
    let name: String
    /// True if this is the device macOS would pick on its own — i.e.
    /// the same device a `nil` `selectedMicDeviceUID` would route to.
    let isSystemDefault: Bool
}

enum AudioInputDevices {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioInputDevices")

    /// Enumerate every connected input device with the system default
    /// flagged. Returns an empty array if any CoreAudio call fails —
    /// the caller treats that the same as "no selection possible",
    /// which silently falls back to the system default behaviour.
    static func list() -> [AudioInputDevice] {
        let ids = allDeviceIDs()
        guard !ids.isEmpty else { return [] }
        let defaultID = systemDefaultInputID()
        return ids.compactMap { id -> AudioInputDevice? in
            guard hasInputStreams(id) else { return nil }
            guard let uid = deviceUID(id), !uid.isEmpty else { return nil }
            let name = deviceName(id) ?? "Unknown input"
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                isSystemDefault: id == defaultID
            )
        }
    }

    /// Look up the live `AudioDeviceID` for a previously-saved UID.
    /// Returns nil if the device has been disconnected, or if it's
    /// present but no longer reports input streams (e.g. user
    /// re-routed a multi-channel interface).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        for id in allDeviceIDs() {
            if deviceUID(id) == uid, hasInputStreams(id) {
                return id
            }
        }
        return nil
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else {
            if sizeStatus != noErr {
                log.error("AudioObjectGetPropertyDataSize failed (status \(sizeStatus, privacy: .public))")
            }
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        )
        guard status == noErr else {
            log.error("AudioObjectGetPropertyData(devices) failed (status \(status, privacy: .public))")
            return []
        }
        return ids
    }

    private static func systemDefaultInputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr ? id : 0
    }

    /// A device qualifies as an "input" if it has at least one
    /// stream on the input scope. Most output-only devices (HDMI
    /// displays, headphones) report zero here.
    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { return false }
        return size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        return stringProperty(id, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        return stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Read a CFString property off an `AudioObjectID`. The
    /// `Unmanaged` dance is required because `AudioObjectGetPropertyData`
    /// returns a +1 reference and Swift won't bridge it implicitly
    /// for us.
    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let unmanaged = cfStr else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
