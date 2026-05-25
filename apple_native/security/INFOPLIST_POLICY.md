# INFOPLIST_POLICY.md — What NOT to Declare in JARVIS Info.plist and Entitlements

**Author:** JARVIS fleet agent, todo `p5-siri-quarantine`  
**Operator:** Robert "Grizzly" Hanson, GMRI  
**Date:** 2026-05-24  
**Applies to:** JARVISMacCockpit, JARVISCompanionApp, JARVISWatchApp

---

## Purpose

This document is **prescriptive policy**: it lists keys and frameworks that MUST NOT appear in JARVIS app targets. Inclusion of any of these keys constitutes a quarantine failure. Code reviewers and fleet agents should treat any PR that adds these keys as a blocking issue until operator explicitly authorizes an exception.

---

## 1. Keys NOT to Declare in Info.plist

### 1.1 Siri Usage Keys

| Key | Reason not to declare |
|-----|-----------------------|
| `NSSiriUsageDescription` | Declares intent to use SiriKit. JARVIS has no SiriKit integration. Presence triggers OS prompt to grant Siri access; absence prevents it. |
| `NSUserActivityTypes` (with Siri-handled activity types) | Do not list activity types that correspond to `INIntent` subclasses or Siri-handled activities. Generic NSUserActivity for state restoration is allowed but must be quarantined via `NSUserActivity.quarantineForJARVIS()` (see `SiriQuarantineGuard.swift`). |

### 1.2 Speech Recognition

| Key | Reason not to declare |
|-----|-----------------------|
| `NSSpeechRecognitionUsageDescription` | JARVIS uses Deepgram (direct audio stream), not `SFSpeechRecognizer`. Declaring this key requests authorization to route audio through Apple's speech recognition pipeline, which shares infrastructure with Siri. Do not declare. |

### 1.3 Apple Intelligence / Core ML Cloud Inference

| Key | Reason not to declare |
|-----|-----------------------|
| `com.apple.developer.natural-language-inference` (hypothetical future entitlement) | Do not declare any entitlement that opts the app into Apple Intelligence cloud inference. This would route JARVIS content through Apple's Private Cloud Compute. |

---

## 2. Frameworks NOT to Link

### 2.1 Intents.framework (SiriKit)

**Do not link** `Intents.framework` in the app target build phase. Linking it without a corresponding SiriKit Intent Extension is a latent surface: it enables `INPreferences` and `INInteraction` APIs that could inadvertently donate to Siri if misused.

**Exception:** `SiriQuarantineGuard.swift` imports `Intents` specifically to call `INPreferences.siriAuthorizationStatus()` and `INInteraction.deleteAllInteractions()` as a quarantine check and cleanup. If this guard file is the only user of `Intents` in the codebase, the linker will include it. This is acceptable and intentional — the import is for quarantine enforcement, not integration.

**How to verify the guard is the only Intents consumer:**
```bash
grep -r "import Intents" /path/to/JARVISMacCockpit/
# Should return only: JARVISMacCockpit/Security/SiriQuarantineGuard.swift
```

### 2.2 IntentsUI.framework

**Do not link** `IntentsUI.framework`. This is the UI layer for SiriKit Intent responses. No use case in JARVIS.

### 2.3 SiriKit-related App Extensions

**Do not create** any app extension with one of these `NSExtensionPointIdentifier` values:
- `com.apple.intents-service` — SiriKit Intent handler extension
- `com.apple.intents-ui-service` — SiriKit Intent UI extension

If any extension bundle in the project contains these identifiers, it must be removed.

---

## 3. Entitlements NOT to Request

### 3.1 Siri Entitlements

| Entitlement | Reason not to request |
|-------------|-----------------------|
| `com.apple.developer.siri` | The SiriKit capability entitlement. Required for SiriKit integration. JARVIS does not integrate SiriKit. Requesting it and shipping a SiriKit Intent Extension would allow Siri to invoke JARVIS actions; that is a quarantine violation. |

---

## 4. What IS Allowed

This policy blocks Siri-related declarations. The following are explicitly permitted:

| Item | Status | Notes |
|------|--------|-------|
| `NSMicrophoneUsageDescription` | ✅ Required | JARVIS uses the mic for always-on audio via AVAudioEngine. Declare with description: "JARVIS uses the microphone for continuous voice awareness." |
| `com.apple.security.audio-input` (macOS entitlement) | ✅ Required | macOS sandboxed app requires this entitlement to access the mic. |
| `AVAudioSession` configuration | ✅ Required | See `MIC_PRIORITY.md` for required session setup. |
| `NSUserActivity` (non-Siri) | ✅ Allowed | For state restoration only. Must call `.quarantineForJARVIS()` on every activity. |
| `CoreSpotlight` (CSSearchableItem) | ⚠️ Review | If used, do not set `contentAttributeSet.relatedUniqueIdentifier` or donate in ways that surface through Siri Suggestions. Default: do not link CoreSpotlight unless there is an explicit non-Siri indexing use case. |

---

## 5. Enforcement Checklist (pre-release gate)

Before every build that ships to TestFlight or production, verify:

- [ ] `grep -r "NSSiriUsageDescription" . ` — returns zero results in any Info.plist
- [ ] `grep -r "NSSpeechRecognitionUsageDescription" .` — returns zero results
- [ ] `grep -r "com.apple.developer.siri" . ` — returns zero results in entitlements files
- [ ] `grep -r "com.apple.intents-service" .` — returns zero results in extension Info.plists
- [ ] `grep -r "import IntentsUI" .` — returns zero results
- [ ] `import Intents` is present only in `SiriQuarantineGuard.swift`
- [ ] `INPreferences.requestSiriAuthorization` is never called (quarantine guard uses status check only)
- [ ] All `NSUserActivity` instances call `.quarantineForJARVIS()` before `becomeCurrent()`
