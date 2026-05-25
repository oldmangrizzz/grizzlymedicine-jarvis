# MIC_PRIORITY.md — JARVIS Always-On Mic: AVAudioSession Strategy and OS Preemption

**Author:** JARVIS fleet agent, todo `p5-siri-quarantine`  
**Operator:** Robert "Grizzly" Hanson, GMRI  
**Date:** 2026-05-24  
**Applies to:** JARVISCompanionApp (iOS/watchOS mic path), JARVISMacCockpit (CoreAudio path)

---

## 1. The Problem

JARVIS is always-on audio aware. The mic must be claimed continuously. Siri (when active), phone calls, FaceTime, media playback, and other apps all compete for the same mic and output session. The OS arbitrates. We cannot override the OS. We can configure the session to maximize JARVIS's priority and document exactly when the OS will preempt us.

This document specifies the required `AVAudioSession` configuration (iOS/watchOS) and the CoreAudio equivalent notes for macOS.

---

## 2. iOS / iPadOS: AVAudioSession Configuration

### 2.1 Required Session Setup

```swift
import AVFoundation

func configureJARVISAudioSession() throws {
    let session = AVAudioSession.sharedInstance()

    // Category: .record
    //   - Silences all output (JARVIS speaks via TTS on a separate engine — see note below).
    //   - Maximizes mic access priority.
    //   - Prevents output interference from muting the mic input.
    //
    //   Alternative if JARVIS needs simultaneous output: .playAndRecord
    //   Use .playAndRecord only if the TTS engine plays through the same audio graph.
    //   For JARVIS's architecture (Deepgram input, XTTS-v2 output via separate process),
    //   .record is preferred for the capture session.
    //
    // Mode: .measurement
    //   - Disables all AGC, noise reduction, and voice processing DSP.
    //   - Raw microphone samples — what JARVIS needs for accurate voice activity detection.
    //   - Do NOT use .voiceChat or .videoChat; those apply Apple's echo cancellation and
    //     processing pipeline, which degrades JARVIS's own VAD.
    //
    // Options: .allowBluetooth
    //   - Allows AirPods/Bluetooth mic input if no wired mic is present.
    //   - Omit .allowBluetoothA2DP — A2DP is for output; irrelevant in .record category.
    //   - Add .duckOthers only if you want to explicitly reduce competing audio during listen.

    try session.setCategory(
        .record,
        mode: .measurement,
        options: [.allowBluetooth]
    )

    // allowHapticsAndSystemSoundsDuringRecording (iOS 13+):
    //   Allows system sounds (notifications, haptic feedback from UIKit) to play
    //   without interrupting the recording session. Default is false — system sounds
    //   trigger an interruption/resume cycle. Setting true keeps the record session
    //   live through notification haptics, which matters for always-on.
    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)

    try session.setActive(true, options: [.notifyOthersOnDeactivation])
}
```

### 2.2 Why `.measurement` Mode

| Mode | AGC | Noise Reduction | Echo Cancel | Best for |
|------|-----|-----------------|-------------|----------|
| `.default` | Yes | Yes | No | General |
| `.voiceChat` | Yes | Yes | Yes | VoIP calls |
| `.measurement` | **No** | **No** | **No** | Signal analysis, VAD, ML inference |
| `.videoRecording` | No | Partial | No | Camera apps |

JARVIS's Deepgram pipeline and any on-device VAD model expect clean PCM at the full frequency range. AGC (automatic gain control) introduces non-linear amplitude changes that corrupt confidence scores. `.measurement` gives us the raw signal.

### 2.3 `allowHapticsAndSystemSoundsDuringRecording`

This `AVAudioSession` instance property (iOS 13+) is critical for always-on operation:

- **Default behavior (false):** Any system sound — a notification chime, a haptic tick from a UI interaction, an incoming call ringtone — causes the audio session to receive an `AVAudioSessionInterruptionTypeWillBegin` notification. The session is briefly suspended. JARVIS drops audio frames during the interruption and must resume.
- **With `true`:** System sounds and haptics play through the output path without interrupting the input session. JARVIS's capture graph keeps running. Notification sounds are audible to the operator; the mic stream is unaffected.

**Limitation:** This does not prevent interruptions from phone calls, FaceTime, or Siri (when Siri is active — another reason to quarantine Siri). Those interruptions are category-level and override `.measurement` regardless.

### 2.4 `setPreferredIOBufferDuration`

For VAD latency, set a low buffer duration:

```swift
// 10ms buffer — matches Deepgram's recommended chunking interval.
// Actual duration is rounded to the nearest hardware-supported value (~5.8ms on A-series).
try session.setPreferredIOBufferDuration(0.01)
```

Shorter buffers = lower latency but higher CPU. 10ms is a practical floor on current devices.

### 2.5 `setPreferredSampleRate`

```swift
// 16 kHz — Deepgram's default; also matches most on-device speech/VAD models.
// If XTTS-v2 output path shares the session (playAndRecord), 48kHz is preferred
// to avoid resampling on output. For pure .record, 16kHz minimizes bandwidth.
try session.setPreferredSampleRate(16000)
```

---

## 3. iOS: Interruption Handling

When the OS interrupts the session (call, FaceTime, Siri if not quarantined, media takeover):

```swift
import AVFoundation

class JARVISAudioSessionManager {
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            // Siri (if somehow active), phone call, FaceTime — OS has taken the session.
            // Stop the AVAudioEngine tap. Log interruption source if available.
            // JARVIS should enter a "mic-suspended" state and surface advisory to operator.
            NotificationCenter.default.post(name: .jarvisMicInterruptionBegan, object: nil)

        case .ended:
            // Resume only if the OS signals it's safe.
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                // Re-activate session and restart capture engine.
                NotificationCenter.default.post(name: .jarvisMicInterruptionEnded, object: nil)
            }
            // If shouldResume is not set (e.g., after a phone call where user may still
            // be on another app), do not auto-resume — wait for operator return or
            // foreground event.

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        // Handles AirPods connect/disconnect, headphone plug/unplug.
        // On route change, the mic input device may have changed.
        // Re-query preferredInput and restart the tap on the new device.
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            NotificationCenter.default.post(name: .jarvisMicRouteChanged, object: nil)
        default:
            break
        }
    }
}

extension Notification.Name {
    static let jarvisMicInterruptionBegan = Notification.Name("jarvis.mic.interruptionBegan")
    static let jarvisMicInterruptionEnded = Notification.Name("jarvis.mic.interruptionEnded")
    static let jarvisMicRouteChanged      = Notification.Name("jarvis.mic.routeChanged")
}
```

---

## 4. What the OS WILL Preempt — Honest List

Regardless of session configuration and Siri quarantine, the following will interrupt the JARVIS mic:

| Preemptor | Session Category | Can JARVIS Prevent It? | Notes |
|-----------|-----------------|----------------------|-------|
| Incoming phone call | All | **No** | CallKit-managed sessions take priority at the telephony stack level. |
| FaceTime / VoIP (CallKit) | All | **No** | Same as above. |
| Siri (if NOT quarantined) | `.record` | **No — this is why we quarantine** | `assistantd` requests mic via CoreAudio at system priority. |
| Emergency alerts (IPAWS, Amber) | All | **No** | Kernel-level. |
| Control Center media controls (output redirect) | `.record` | N/A (no output) | Does not affect `.record` input. |
| Another app calling `setActive(true)` with `.duckOthers` | `.record` | Partially — `.record` is not ducked, but may be interrupted if the other app requests `.notifyOthersOnDeactivation` | Usually coexist. |
| Screen recording (internal) | `.record` | No | Screen recording tap may merge with our input. |

**Bottom line:** With Siri quarantined, the remaining unpreventable preemptors are phone/FaceTime and emergency alerts. JARVIS should handle `interruptionNotification` gracefully and resume cleanly.

---

## 5. macOS: CoreAudio Notes

macOS does not use `AVAudioSession`. The equivalent is `AVCaptureSession` (for simple use cases) or direct CoreAudio `AudioUnit` / `AudioDeviceID` access (for the low-latency always-on path).

### 5.1 JARVIS Mac Audio Path

The Mac cockpit uses `AVAudioEngine` with a microphone input node:

```swift
// Conceptual — the actual wiring is in JARVISNativeRuntime (C++/ObjC++)
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let format = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    // Forward PCM buffer to Deepgram stream
}
try engine.start()
```

On macOS:
- `AVAudioEngine` manages the CoreAudio HAL session internally.
- `inputNode.outputFormat(forBus:)` returns the system's current default input device format.
- **No explicit `setCategory` call is needed or available on macOS.**
- The mic is always accessible to sandboxed apps with the `com.apple.security.audio-input` entitlement.

### 5.2 CoreAudio Priority on macOS

macOS does not have a session priority system equivalent to iOS's `AVAudioSession`. The CoreAudio HAL uses a first-come-first-served tap model — multiple processes can simultaneously read the same input device. This is more permissive than iOS.

**Implication:** On macOS, Siri (`assistantd`) and JARVIS can both read the mic at the same time if Siri is active. This is another reason to quarantine Siri via MDM profile on macOS — not to prevent JARVIS from getting the mic, but to prevent `assistantd` from consuming CPU, Neural Engine bandwidth, and network traffic processing every utterance.

### 5.3 `allowHapticsAndSystemSoundsDuringRecording` on macOS

This API is iOS-only. macOS does not have an equivalent — system sounds (notification sounds) play independently of CoreAudio input taps and do not interrupt JARVIS's audio capture.

---

## 6. watchOS Considerations

- watchOS uses `AVAudioSession` (same API as iOS, more restricted subset).
- The Watch mic is low-fidelity (mono, ~16kHz native). Appropriate for VAD.
- Background audio recording on watchOS requires the `Audio` background mode in capabilities — and watchOS limits background execution heavily.
- For always-on mic on Watch: the `WKExtension` must be in foreground or have the Audio background mode. This is a significant power constraint.
- Recommendation: JARVIS on Watch should be a relay to the iPhone, not an independent always-on mic. The iPhone is the always-on mic owner; Watch is a control surface and status display.

---

## 7. Session Configuration Summary (Quick Reference)

```
Platform:  iOS / iPadOS
Category:  .record
Mode:      .measurement
Options:   [.allowBluetooth]
allowHapticsAndSystemSoundsDuringRecording: true
preferredIOBufferDuration: 0.01 (10ms)
preferredSampleRate: 16000 Hz

Platform:  macOS
Session:   AVAudioEngine with inputNode tap (CoreAudio HAL)
Format:    device-native (typically 48kHz float32, convert to 16kHz PCM for Deepgram)
Entitlement: com.apple.security.audio-input

Platform:  watchOS
Recommendation: relay to iPhone; do not run always-on mic independently
```
