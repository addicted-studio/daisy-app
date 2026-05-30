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

    /// Stable UID for a live `AudioDeviceID`, or nil if CoreAudio can't
    /// resolve it. The inverse of `deviceID(forUID:)`. `AudioRecorder`
    /// uses this to remember — by stable identity, not the session-local
    /// `AudioDeviceID` — which device a recording is actually bound to,
    /// so a mid-session Bluetooth default-input flip can be told apart
    /// from the device the user/engine is on.
    static func uid(for id: AudioDeviceID) -> String? {
        return deviceUID(id)
    }

    /// True if `id` uses a Bluetooth transport (or, for an aggregate,
    /// any active sub-device does). Lets the route-change recovery gate
    /// its "keep the current mic" decision on transport: connecting
    /// AirPods for *output* drags the default *input* onto their SCO
    /// mic, which frequently delivers pure silence — we want to ignore
    /// that flip, but still follow an intentional wired/USB input
    /// change. Aggregate-aware (AirPods nested in a multi-output
    /// aggregate still read as Bluetooth). Mirrors the equivalent check
    /// on the system-audio (output) side in `SystemAudioCapture`.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tStatus = AudioObjectGetPropertyData(
            id, &transportAddress, 0, nil, &size, &transportType
        )
        guard tStatus == noErr else { return false }

        if transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }

        // Aggregate? Drill into the active sub-devices once (no deep
        // recursion — a direct transport check per sub covers the real
        // configs we care about, e.g. AirPods inside a multi-output).
        guard transportType == kAudioDeviceTransportTypeAggregate else {
            return false
        }
        var subDevicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var subDevicesSize: UInt32 = 0
        let szStatus = AudioObjectGetPropertyDataSize(
            id, &subDevicesAddress, 0, nil, &subDevicesSize
        )
        guard szStatus == noErr, subDevicesSize > 0 else { return false }

        let count = Int(subDevicesSize) / MemoryLayout<AudioObjectID>.size
        var subDevices = [AudioObjectID](repeating: 0, count: count)
        let listStatus = subDevices.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var sz = subDevicesSize
            return AudioObjectGetPropertyData(
                id, &subDevicesAddress, 0, nil, &sz, buf.baseAddress!
            )
        }
        guard listStatus == noErr else { return false }

        for sub in subDevices where sub != kAudioObjectUnknown {
            var subTransport: UInt32 = 0
            var subSize = UInt32(MemoryLayout<UInt32>.size)
            var subAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let s = AudioObjectGetPropertyData(
                sub, &subAddress, 0, nil, &subSize, &subTransport
            )
            if s == noErr,
               subTransport == kAudioDeviceTransportTypeBluetooth
                || subTransport == kAudioDeviceTransportTypeBluetoothLE {
                return true
            }
        }
        return false
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

    /// System default input device ID. Exposed (not private) so
    /// `AudioRecorder.applyPreferredInputDevice(uid:)` can fall through
    /// to it explicitly when the user picked "System default" — pinning
    /// the AUHAL to the *current* default rather than leaving it bound
    /// to a stale ID after a route change. Returns 0 if CoreAudio fails;
    /// callers treat that the same as "no pinning possible".
    static func systemDefaultInputID() -> AudioDeviceID {
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

    /// Read the *actual* hardware stream sample rate from CoreAudio.
    /// Used as a defensive cross-check against `AVAudioNode.outputFormat(forBus:)`
    /// inside the route-change recovery path — after pinning the AUHAL
    /// to a new device, AVAudioEngine has been observed (macOS 26.2,
    /// Apple DevForum 680785 / 683348) to return the *previous* device's
    /// cached format from `outputFormat(forBus:)`. Installing a tap with
    /// that stale format trips Apple's internal assertion
    /// `format.sampleRate == inputHWFormat.sampleRate` and crashes the
    /// app. This helper lets `AudioRecorder` cross-check and fall to
    /// paused on disagreement rather than ship the assertion to users.
    ///
    /// Returns nil if CoreAudio refuses or the device has no input scope.
    static func streamFormatSampleRate(for id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            if status != noErr {
                log.error("StreamFormat read failed for device \(id, privacy: .public) (status \(status, privacy: .public))")
            }
            return nil
        }
        return format.mSampleRate
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
