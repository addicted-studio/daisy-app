# QA test plan — Daisy 1.0.4 (audio survival + calendar auto-stop)

Two real-tester bug reports went into this release. The tester needs to
verify both are fixed and that we didn't regress the paths that were
already working. The plan below is ordered: smoke tests first, edge
cases second, then logging hooks if anything looks off.

Before starting, prime Terminal with the diagnostic stream so a failure
is captured live, not reconstructed afterwards:

```bash
log stream --level debug --style compact \
  --predicate 'subsystem == "app.essazanov.Daisy" AND (category == "AudioRecorder" OR category == "SystemAudio" OR category == "AutoStop" OR category == "Calendar/Perm" OR category == "Session")'
```

Leave that running in a side terminal. Ctrl-C and copy whatever it
shows whenever a scenario fails.

---

## A. Headphones plug/unplug mid-recording

**A1. USB headphones, plug mid-recording (the original bug).**
Start a meeting recording with built-in mic + speakers. Play a YouTube
clip in another window so system-audio loopback has something to
capture. Speak a phrase. After ~10 s, plug in a USB headset. Speak for
another 10 s. After 10 s, unplug. Speak again. Stop.

Open the saved recording. Expected: continuous mic audio across the
plug + unplug. System-audio loopback present throughout. A route-change
toast appears once or twice. No "audio stopped — recording paused"
toast, no silent gaps longer than ~1 s.

**A2. 3.5mm headphones, same flow.**
Same as A1 but plug into the 3.5mm jack (headphones with no
microphone). Mic should stay on built-in; system-audio loopback
continues. The new CoreAudio default-input listener should fire even
though `AVAudioEngineConfigurationChange` may not — that's the whole
point of the listener.

**A3. Adversarial: rapid plug/unplug.**
Start recording. Within 30 seconds, plug + unplug USB headphones three
times in a row (~5 s between toggles). Stop. No crash, no stuck Paused
state. Some short dropouts are acceptable; what we're checking is that
the watchdog doesn't false-fire. The 2-second debounce inside
`handleConfigurationChange` should collapse the rapid-fire into ≤2
recovery passes.

**A4. Watchdog smoke test.**
Start recording with built-in mic. In System Settings → Sound, switch
the input to a device with no signal (mute the built-in or use an
aggregate device with nothing wired in). Within ~5 s, expect a warning
toast: "Mic stopped delivering audio — recording paused. Hit Resume to
retry." Session should be in Paused state with the orange widget colour.
Switch input back to built-in, hit Resume, verify capture restarts.

**A5. Pause + swap + Resume.**
Start recording on built-in. Pause manually (hotkey or widget).
Plug in USB headphones. Wait 5 s. Hit Resume. Speak. Stop. Post-resume
audio should land on the new device. No auto-stop watchdog firing (it's
disarmed during paused state).

---

## B. Calendar auto-stop

**B1. Manual hotkey start with auto-stop ON (the original bug).**
Create a calendar event in Apple Calendar starting in 2 minutes,
3 minutes long. Make sure Settings → General → Calendar has "Stop when
the event ends" on and your grace period is set (e.g., 0 or 1 min).
Wait until the event start time has passed by 5–10 seconds. Hit the
record hotkey manually — do NOT wait for Daisy to auto-start. Speak
through the meeting. Expected: at `event.endDate + graceSec`, Daisy
fires the 30-second warning toast (if grace ≥ 30 s) and then stops
automatically. Saved session has the calendar event's title.

In the log stream you should see:
- `AutoStop: bindCurrentMeetingIfPossible: auto-bound to '<title>' …`
- `AutoStop: Auto-stop armed for '<title>' at <date>`

**B2. Calendar-triggered auto-start (no-regress).**
Create another event 2 minutes out. Do nothing. Let Daisy auto-start
from `CalendarService.tick()`. At the event end, auto-stop should fire
exactly the same way as in B1.

**B3. Back-to-back meetings.**
Create two events: 10:00–10:15 and 10:15–10:30. Verify that at 10:15
the first session stops & saves, the second starts fresh under the
new event's title, and at 10:30 the second auto-stops cleanly. No
merged session, no orphaned timer firing from the first.

**B4. Overlap edge case — earliest start wins.**
Create two overlapping events: 10:00–10:30 and 10:15–10:45. At 10:20
hit the record hotkey manually. `bindCurrentMeetingIfPossible()` picks
the earliest-started, still-running meeting — the 10:00 one — so
auto-stop fires at 10:30. If you intended the 10:15 event, edit the
session title manually after binding and ignore the early stop. (Open
backlog: surface a chooser when multiple candidates match.)

**B5. User-typed title is preserved through auto-bind.**
Before any calendar event begins, manually start a session and type
your own title ("Daily review", say). Let the calendar event start
afterwards. The session title must NOT be overwritten — only the
auto-generated `Meeting YYYY-MM-DD HH:MM` placeholder gets replaced.

---

## C. Settings UI

**C1. Live calendar access reflects in General.**
Open Settings → General. Note that the Calendar section is enabled.
In another window, open System Settings → Privacy & Security →
Calendars and revoke Daisy. Tab back to Daisy → Settings → General.
The Calendar section should disable itself without restarting. The
Permissions tab should show Denied for Calendar.

Re-grant in System Settings, tab back. The General section re-enables
within a second (driven by `NSApplication.didBecomeActiveNotification`
inside `SystemPermissions`).

**C2. Connections sidebar no longer has Calendar tab.**
Open the Connections destination in the sidebar. Tabs should be
Notion / MCP server / Auto-routing only. No Calendar tab.

**C3. DMG installer window background.**
Mount the new `Daisy-1.0.4.dmg`. The Finder window should show: the
Daisy app icon, an Applications shortcut, an arrow between them, and a
plain peach gradient background. No second smaller daisy graphic in the
lower-right corner.

---

## D. Regression risks (run these last, but DO run them)

**D1. AirPods (BT) reconnect mid-recording.**
This is the watchdog's likeliest false-positive risk — BT mic warmup
after reconnect can run >1 s. Start recording on AirPods, walk out of
range so they disconnect, walk back to reconnect. Expected: route
change recovers, watchdog (5 s deadline) doesn't trip. If it DOES trip
falsely, that's a P1 — the deadline needs to be transport-aware (BT
gets, say, 10 s).

**D2. User-pinned USB mic unplugged mid-session.**
Open Settings → General → Audio, pick a specific external USB mic
(not "System default"). Start recording. Unplug the USB mic. Expected:
graceful fall-through to system default (logged warning is fine), tap
re-installs, recording continues. The pin should not become a hard
failure.

**D3. Sleep / wake mid-recording.**
Start recording. Sleep the Mac for 30 s. Wake. Expected: route-change
listener may fire (cheap), watchdog doesn't trip from wake delay,
session continues OR pauses with a clear toast. No silent dead recording.

---

## E. Pre-release sanity checklist

Before the final `./scripts/release.sh 1.0.4 N`:

1. **Build number.** `N` must be `> 8` (the last published one in
   `Daisy-web/public/appcast.xml`). The sanity check in `release.sh`
   will refuse otherwise — that's expected.
2. **Release notes file exists** at `scripts/release-notes/1.0.4.md`.
   It does, but verify before running.
3. **Entitlements untouched.** Open `Daisy/Daisy.entitlements` and
   confirm the three required keys are still present:
   - `com.apple.security.device.audio-input`
   - `com.apple.security.personal-information.calendars`
   - `com.apple.security.network.client`
4. **`appcast.xml` writable.** `cd ../Daisy-web && git status` —
   confirm nothing is in a bad state from earlier sessions today.
5. **Sparkle key still in Keychain.** Quick check:
   `security find-generic-password -s 'https://sparkle-project.org' 2>&1 | head -1`
   — should print a `keychain:` line, NOT `item not found`.
6. **Tester opens Console.app** with the predicate at the top of this
   file BEFORE running A1 / B1, so we have logs if anything fails.

---

## F. If something fails

Grab the log stream output (Cmd-C inside Terminal) and the saved session
folder (everything under `~/Daisy/Sessions/<that session>`). Send both.
The combination of `AudioRecorder` + `AutoStop` log lines around the
failure window plus the session's `microphone.caf` + `system_audio.caf`
file sizes is usually enough to diagnose in 5 minutes.
