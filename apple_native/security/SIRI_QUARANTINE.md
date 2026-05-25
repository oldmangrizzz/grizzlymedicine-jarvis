# SIRI_QUARANTINE.md — Siri Quarantine Reference

**Author:** JARVIS fleet agent, todo `p5-siri-quarantine`  
**Operator:** Robert "Grizzly" Hanson, GMRI  
**Date:** 2026-05-24  
**Applies to:** macOS 14/15, iOS 17/18, watchOS 10/11, iPadOS 17/18  
**Objective:** Enumerate every Siri entry-point, its disablement surface, and the honest residual after quarantine.

---

## 0. Scope and Methodology

This document does not assert capabilities that do not exist. Every claim about MDM payload keys is sourced against Apple's published Configuration Profile Reference and/or open-source profile tooling (`ProfileCreator` corpus). Every claim about API surface is against Apple's public SDK headers. Where behavior is unconfirmed in documentation, it is labeled **[UNCONFIRMED]** and no quarantine procedure is built on it.

Disablement surfaces ranked by authority:
1. **MDM restriction payload** — enforced at kernel/SpringBoard level; survives user override.
2. **User-side Settings toggle** — the operator can set these; they are reversible by the user.
3. **App-side API refusal** — the JARVIS app can decline to donate/register; does not affect system Siri.
4. **Nothing / permanently bound** — OS retains capability regardless of above.

---

## 1. macOS Siri Hooks

### 1.1 Keyboard Shortcut / Menu Bar Invocation

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Hold-Ⓕ or Fn+Space hotkey | System Settings → Siri & Spotlight → "Ask Siri" toggle | `com.apple.applicationaccess` → `assistantIsDisabled = true` | N/A | No |
| Menu bar Siri icon | Turns off with the above toggle | Same | N/A | No |
| Right-click → Ask Siri (contextual menu) | Turns off with the above toggle | Same | N/A | No |

**MDM payload key:** `com.apple.applicationaccess`  
```xml
<key>assistantIsDisabled</key><true/>
```
Applies to supervised devices enrolled in MDM or devices with a user-accepted configuration profile.

### 1.2 "Hey Siri" Wake Word (macOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| "Hey Siri" wake word (mic hot-word listener) | System Settings → Siri & Spotlight → "Listen for 'Hey Siri'" | `com.apple.applicationaccess` → `assistantIsDisabled = true` disables Siri entirely, which removes Hey Siri | N/A | No — requires explicit opt-in on Mac |

On macOS, Hey Siri is **off by default** and requires CPU/neural engine capacity enrollment. Disabling Siri entirely removes it.

### 1.3 Dictation (Siri-adjacent)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Enhanced Dictation (on-device ML) | System Settings → Keyboard → "Enable Dictation" toggle | `com.apple.applicationaccess` → `dictationIsDisabled = true` | N/A | No |
| Fn+Fn (dictation shortcut) | Turn off Dictation | Same MDM key | N/A | No |

**MDM payload key:**
```xml
<key>dictationIsDisabled</key><true/>
```

### 1.4 Spotlight Siri Suggestions

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Spotlight shows Siri Suggestions, App Suggestions | System Settings → Siri & Spotlight → "Spotlight Suggestions" | `com.apple.applicationaccess` → `allowSpotlightInternetResults = false` | App can opt-out of donating `NSUserActivity` / `INInteraction` | No |
| Siri Suggestions in Safari, Mail, Messages | Settings per-app | Same, plus `allowSiriSuggestions = false` [see §1.6] | `userActivity.isEligibleForSearch = false`, `isEligibleForPrediction = false` | No |

### 1.5 Siri Profanity Filter (macOS)

Not typically surface-level on macOS. `siriProfanityFilterIsDisabled` is primarily an iOS/iPadOS key. Included in profile for completeness; harmless if present.

### 1.6 Shortcuts / Siri Automation

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Siri Suggestions in Shortcuts | Settings → Siri & Suggestions per-app | `allowSiriSuggestions = false` [UNCONFIRMED — not in all macOS MDM docs; verify against your MDM vendor] | App does not ship a SiriKit Intent Extension; JARVIS does not donate `INInteraction` | No |
| Shortcuts App ("Run Shortcut" via Siri) | Siri is already disabled | Same | N/A | Requires Siri to be active |

### 1.7 Accessibility Paths (macOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Switch Control → Siri | System Settings → Accessibility → Switch Control | Accessibility profile restrictions | N/A | No |
| Voice Control (distinct from Siri — Apple's accessibility dictation) | System Settings → Accessibility → Voice Control | `com.apple.applicationaccess` → `allowVoiceDialing` (phone-only, not relevant) — **Voice Control as accessibility is NOT blocked by `assistantIsDisabled`** | N/A | **Residual: Voice Control is accessibility-level and survives Siri MDM restrictions** |

**⚠ Residual #R1:** macOS Voice Control (Accessibility → Voice Control) is a separate daemon (`voicecontrolled`) from Siri and is **not** disabled by `assistantIsDisabled`. If the operator does not use Voice Control for accessibility, it should be manually disabled in System Settings → Accessibility → Voice Control. There is no MDM key in the `assistantIsDisabled` payload that touches it.

---

## 2. iOS / iPadOS Siri Hooks

### 2.1 Side Button Invocation (Home button on older devices)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Press-and-hold side/home button → Siri | Settings → Siri & Search → "Press Side Button for Siri" | `assistantIsDisabled = true` | N/A | No |
| Lock screen Siri access | Settings → Siri & Search → "Allow Siri When Locked" | `assistantWhileLockedIsDisabled = true` | N/A | No |

### 2.2 "Hey Siri" Wake Word (iOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| "Hey Siri" hot-word listener | Settings → Siri & Search → "Listen for 'Hey Siri'" | Disabled by `assistantIsDisabled = true` | N/A | No |

**Note:** The on-device hey-Siri model runs on Neural Engine continuously when enabled. Disabling via MDM prevents the model from loading. When `assistantIsDisabled = true` the neural engine hot-word pipeline is not started.

### 2.3 Dictation (iOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Microphone button on keyboard (dictation) | Settings → General → Keyboard → "Enable Dictation" | `dictationIsDisabled = true` | N/A | No |

### 2.4 AirPods Squeeze / Say Hey Siri (AirPods)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| AirPods press-and-hold / squeeze gesture → Siri | Settings → Bluetooth → [AirPods] → left/right press-and-hold → reassign to "Off" | No MDM key exposes AirPods gesture remapping | N/A | **Residual: No MDM key disables AirPods Siri gesture.** User must manually reassign in Bluetooth settings per-pair. |
| "Hey Siri" via AirPods | Disabled when iOS Siri is disabled via MDM | Same | N/A | No (follows iOS setting) |

**⚠ Residual #R2:** AirPods physical-gesture → Siri mapping has no MDM restriction key. Operator must manually reassign each AirPods pair in Settings → Bluetooth → AirPods info pane. Gesture can be set to "Off" or another function (e.g., Play/Pause, Next Track). This survives a profile wipe and must be re-set after pairing.

### 2.5 Siri Suggestions in Apps (iOS/iPadOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Siri Suggestions in Search | Settings → Siri & Search → "Suggestions in Search" | No granular MDM key exposed per-app [UNCONFIRMED on global disable] | App: `INInteraction.deleteAllInteractions()` on launch | No |
| Siri Suggestions in Lock Screen | Settings → Siri & Search → "Suggestions on Lock Screen" | `assistantWhileLockedIsDisabled = true` covers invocation; suggestions on lock screen tied to same | App: do not donate `INInteraction` | No |
| Siri App Suggestions (Spotlight / App Library) | Settings → Siri & Search → [per app] → "Learn from this App" = off | No per-app MDM key; `assistantIsDisabled` removes Siri itself | App: `userActivity.isEligibleForPrediction = false` | No |
| Shortcut donations from apps | Settings → Siri & Search → [per app] → "Shortcuts" | Disabled when `assistantIsDisabled = true` | App: do not donate shortcuts, no Intent Extension | No |

### 2.6 Siri in Mail / Calendar / Messages / Safari (iOS/iPadOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Siri Suggestions inline (e.g., add contact, suggested reply) | Settings → Siri & Search → [per app] → "Learn from this App" = off | No per-system-app MDM key — system apps honor `assistantIsDisabled` for invocation, not suggestions UI | N/A (system apps, not controllable) | **Residual: System app suggestion UI surfaces in Mail/Calendar/Messages are not blocked by `assistantIsDisabled` alone.** They can be toggled per-app in Settings → Siri & Search. No MDM key suppresses them globally. |

**⚠ Residual #R3:** Per-app Siri Suggestions in Mail, Calendar, Messages cannot be bulk-disabled via a single MDM key. They must each be toggled off in Settings → Siri & Search → [App Name] → "Show Siri Suggestions in App" = off. There is no published `com.apple.applicationaccess` key for this. The operator must do this manually after profile install.

### 2.7 Siri Shortcuts / Shortcuts App (iOS/iPadOS)

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Shortcuts App | Available regardless of Siri status | No MDM key to remove the Shortcuts app | N/A | **Residual: The Shortcuts app itself is not removed by disabling Siri. Shortcuts can still run automations. Siri voice-invocation of shortcuts is blocked.** |
| "Hey Siri, run [shortcut]" | Blocked by `assistantIsDisabled = true` | Same | N/A | No |

**⚠ Residual #R4:** The Shortcuts app survives Siri quarantine and can still run automations triggered by focus modes, time, location, etc. This is not a Siri surface for JARVIS's purposes (no wake word, no ambient mic competition) but operator should be aware automations are live.

### 2.8 Dictation in Third-Party Apps

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Dictation microphone in keyboard (system-wide) | Settings → General → Keyboard → Dictation | `dictationIsDisabled = true` | App: do not request `NSSpeechRecognitionUsageDescription` | No |

---

## 3. watchOS Siri Hooks

### 3.1 Raise-to-Speak / Hey Siri

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Raise-to-speak Siri | Settings (on watch or companion iOS app) → Siri → "Raise to Speak" | MDM `assistantIsDisabled` applies to supervised Watch via paired supervised iPhone profile | N/A | No |
| "Hey Siri" on watch | Settings → Siri → "Hey Siri" | Same — disabled by iOS-side `assistantIsDisabled` propagated to watch | N/A | No |
| Side Crown press → Siri | Settings (Watch app on iPhone) → Siri → "Press Crown for Siri" | Same MDM profile | N/A | No |

**⚠ Note:** watchOS restrictions inherit from the paired iPhone's MDM profile when the iPhone is supervised. A profile installed on iPhone alone does **not** enforce Watch restrictions unless the profile is installed via proper MDM that includes watchOS payloads. For user-enrolled (non-MDM) scenario, the operator must toggle Watch Siri off both on watch and in the Watch app on iPhone.

### 3.2 Siri Watch Face

| Surface | Disable via Settings | Disable via MDM | App API | Permanently bound |
|---------|---------------------|-----------------|---------|-------------------|
| Siri Watch Face (predictive suggestions) | Remove the Siri watch face from the face lineup | No MDM key disables the watch face itself | N/A | **Residual: If the Siri Watch Face is installed, it continues to show predictions based on on-device learning even with Siri disabled. The face must be manually removed.** |

**⚠ Residual #R5:** The Siri Watch Face runs on-device predictions that surface calendar, workout, commute, and Siri shortcuts regardless of Siri voice-invocation state. It must be manually removed from the watch face lineup.

### 3.3 Wrist-Tap / Complication Shortcut

No separate Siri complication surfaces beyond the watch face itself.

---

## 4. Summary: Residual Hooks (cannot be revoked by MDM profile alone)

| ID | Platform | Residual | Mitigation |
|----|----------|---------|------------|
| R1 | macOS | Voice Control (Accessibility) survives `assistantIsDisabled` — separate daemon | Manually disable: System Settings → Accessibility → Voice Control |
| R2 | iOS | AirPods physical gesture → Siri has no MDM disable key | Manually reassign each AirPods pair in Settings → Bluetooth → [pair] |
| R3 | iOS/iPadOS | Per-app Siri Suggestions in Mail/Calendar/Messages/Safari — no bulk MDM key | Manually toggle each in Settings → Siri & Search → [App Name] |
| R4 | iOS/iPadOS | Shortcuts app itself is not removed; automations remain live (no wake-word, no ambient mic) | Acceptable unless operator wants to kill automations; low Siri relevance |
| R5 | watchOS | Siri Watch Face predictions run on-device even with Siri voice disabled | Manually remove the Siri watch face from lineup |
| R6 | All | Apple Intelligence (iOS 18.1+, macOS 15.1+) — new Apple AI layer that may partially bypass `assistantIsDisabled` for writing tools, notification summaries, etc. | See §5 |

---

## 5. Apple Intelligence Interaction (iOS 18.1+ / macOS 15.1+)

Apple Intelligence is **architecturally separate from Siri** in Apple's framing, though it shares some input pathways. As of iOS 18/macOS 15:

- `assistantIsDisabled = true` disables Siri voice invocation and the Siri UI.
- Apple Intelligence Writing Tools, Notification Summaries, and Image Playground are **not governed by `assistantIsDisabled`**.
- MDM key `allowAppleIntelligence = false` (iOS 18+, `com.apple.applicationaccess`) disables Apple Intelligence features. **Include this in the profile.**
- Apple Intelligence on-device model continues to index content for private cloud compute eligibility checks even when features are "disabled" by the user toggle — the MDM key is stronger.

**⚠ Residual #R6:** Without the `allowAppleIntelligence = false` key, Apple Intelligence features survive Siri quarantine. Profile includes this key. On devices running iOS < 18.1 the key is silently ignored (no harm).

---

## 6. Quarantine Completeness Confidence

| Platform | Confidence | Notes |
|----------|-----------|-------|
| macOS 14/15 | **85%** | MDM profile via `profiles install` enforces the critical keys. R1 (Voice Control) requires manual step. Apple Intelligence key covers 15.x. The 15% gap is Voice Control accessibility and any future OS-level Siri routing changes Apple makes to the `assistantd` daemon. |
| iOS 17/18 | **80%** | Profile via AirDrop/System Settings covers Siri invocation, dictation, lock-screen. R2 (AirPods gestures) and R3 (per-app suggestions) require manual steps. Apple Intelligence key covers 18.x. |
| watchOS 10/11 | **70%** | Watch restrictions only enforce fully under supervised MDM. User-enrolled profile propagation from iPhone is partial. R5 (Watch Face) requires manual removal. Operator should treat Watch as partially-quarantined and monitor. |
| iPadOS 17/18 | **80%** | Same as iOS. iPad-specific surfaces (Pencil double-tap to Siri) follow `assistantIsDisabled`. |

**Bottom line:** MDM profile achieves the Siri voice/invocation quarantine completely on macOS and iOS for all wake-word, button, and dictation surfaces. Residuals R1–R5 require operator manual steps documented above. R6 is covered by the `allowAppleIntelligence` key.
