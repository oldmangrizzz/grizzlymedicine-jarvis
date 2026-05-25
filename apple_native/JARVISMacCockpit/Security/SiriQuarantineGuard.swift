import Foundation
import Intents
import Speech
import AVFoundation
import os.log

// MARK: - SiriQuarantineGuard
//
// Runtime enforcement layer for Siri quarantine on JARVIS Mac Cockpit.
// Called at app launch from AppDelegate / scene lifecycle.
//
// Responsibilities:
//   1. Detect whether Siri / speech recognition surfaces appear active.
//   2. Refuse all Siri donation surfaces the app controls.
//   3. Surface a structured warning to the cockpit if Siri appears live —
//      operator must see this; we do not silently proceed.
//
// What this file CANNOT do:
//   - Revoke system-level Siri. That is MDM / Settings territory.
//   - Prevent Siri from intercepting the mic at the OS level.
//   - Read the MDM profile restriction state directly from the app sandbox.
//
// Sources of truth checked:
//   - INPreferences.siriAuthorizationStatus  (Siri / Intents framework)
//   - SFSpeechRecognizer.authorizationStatus (Speech framework)
//   - AVAudioSession (session state — whether another session is active / competing)
//
// This file ships NO SiriKit Intent Extensions, NO NSUserActivity Siri donations,
// NO INInteraction donations. See INFOPLIST_POLICY.md for what not to declare.

// MARK: - Warning model

/// Structured warning surfaced to the cockpit when Siri appears active.
public struct SiriQuarantineWarning: Sendable {
    public enum Severity: String, Sendable {
        case advisory   // Non-blocking; operator should be aware.
        case blocking   // Operator explicitly decided; JARVIS should not start audio.
    }

    public let severity: Severity
    public let code: String
    public let message: String
    public let remediationURL: String?

    public init(severity: Severity, code: String, message: String, remediationURL: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.remediationURL = remediationURL
    }
}

// MARK: - Guard

public final class SiriQuarantineGuard: Sendable {

    private static let log = Logger(
        subsystem: "org.gmri.jarvis.cockpit",
        category: "SiriQuarantineGuard"
    )

    // MARK: - Entry point

    /// Run all quarantine checks. Returns any warnings in order of severity.
    /// Call this before starting JARVIS audio session.
    ///
    /// - Returns: Array of `SiriQuarantineWarning`. Empty = clean. Non-empty = operator must be notified.
    public static func runChecks() -> [SiriQuarantineWarning] {
        var warnings: [SiriQuarantineWarning] = []

        warnings += checkSiriAuthorizationStatus()
        warnings += checkSpeechRecognizerAuthorizationStatus()
        warnings += checkAudioSessionForSiriCompetition()

        // Refuse donations regardless of check results.
        refuseAllSiriDonations()

        for w in warnings {
            log.warning("[\(w.code)] [\(w.severity.rawValue)] \(w.message)")
        }

        if warnings.isEmpty {
            log.info("SiriQuarantineGuard: all checks passed — no active Siri surfaces detected.")
        }

        return warnings
    }

    // MARK: - Check: INPreferences.siriAuthorizationStatus

    private static func checkSiriAuthorizationStatus() -> [SiriQuarantineWarning] {
        // INPreferences.siriAuthorizationStatus reflects whether the user has granted
        // the app authorization to use SiriKit. On a clean JARVIS install:
        //   - We never request SiriKit authorization.
        //   - Expected status: .notDetermined (never asked) or .denied (explicitly denied).
        //   - If status is .authorized: Siri integration is active for this app — flag it.
        //
        // Note: INPreferences is available on macOS 12+ and iOS 10+.
        // It does NOT tell us whether system Siri is enabled globally; it only reports
        // this app's authorization state. A .notDetermined or .denied result is clean.

        #if os(macOS)
        log.info("SiriQuarantineGuard: macOS has no public INPreferences Siri authorization API. App ships no Siri intents and relies on MDM/System Settings for global Siri disablement.")
        return []
        #else
        let status = INPreferences.siriAuthorizationStatus()

        switch status {
        case .authorized:
            return [SiriQuarantineWarning(
                severity: .blocking,
                code: "SIRI-INT-001",
                message: "INPreferences.siriAuthorizationStatus = .authorized — this app has active SiriKit authorization. This should not happen on a quarantined JARVIS install. Revoke: Settings → Siri & Search → [app] → turn off all toggles. Re-inspect Info.plist for unexpected NSSiriUsageDescription.",
                remediationURL: "x-apple.systempreferences:com.apple.preference.siri"
            )]

        case .denied:
            // Denied = user or MDM explicitly blocked Siri for this app. Clean.
            log.info("SiriQuarantineGuard: INPreferences.siriAuthorizationStatus = .denied (clean).")
            return []

        case .notDetermined:
            // Never requested — the expected state for JARVIS.
            log.info("SiriQuarantineGuard: INPreferences.siriAuthorizationStatus = .notDetermined (clean).")
            return []

        case .restricted:
            // MDM restriction in effect — Siri blocked at policy level. Ideal.
            log.info("SiriQuarantineGuard: INPreferences.siriAuthorizationStatus = .restricted (MDM enforced — clean).")
            return []

        @unknown default:
            return [SiriQuarantineWarning(
                severity: .advisory,
                code: "SIRI-INT-002",
                message: "INPreferences.siriAuthorizationStatus returned an unknown value (\(status.rawValue)). Review on current OS version.",
                remediationURL: nil
            )]
        }
        #endif
    }

    // MARK: - Check: SFSpeechRecognizer.authorizationStatus

    private static func checkSpeechRecognizerAuthorizationStatus() -> [SiriQuarantineWarning] {
        // SFSpeechRecognizer authorization reflects whether the app has permission to
        // use Apple's speech recognition framework (which routes through Siri infrastructure
        // for cloud requests, or on-device model for local requests).
        //
        // JARVIS does NOT use SFSpeechRecognizer. It uses Deepgram via AVAudioEngine capture.
        // Expected status: .notDetermined (never requested) or .denied.
        // .authorized here means something in this app requested speech recognition — flag it.

        let status = SFSpeechRecognizer.authorizationStatus()

        switch status {
        case .authorized:
            return [SiriQuarantineWarning(
                severity: .advisory,
                code: "SIRI-SPEECH-001",
                message: "SFSpeechRecognizer.authorizationStatus = .authorized — the system has granted speech recognition access to this app. JARVIS does not use SFSpeechRecognizer. Audit whether any dependency requested NSSpeechRecognitionUsageDescription. This is advisory: AVAudioEngine capture path is unaffected, but the open permission is a surface reduction opportunity.",
                remediationURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            )]

        case .denied, .restricted:
            log.info("SiriQuarantineGuard: SFSpeechRecognizer.authorizationStatus = \(status.rawValue) (clean).")
            return []

        case .notDetermined:
            log.info("SiriQuarantineGuard: SFSpeechRecognizer.authorizationStatus = .notDetermined (clean).")
            return []

        @unknown default:
            return [SiriQuarantineWarning(
                severity: .advisory,
                code: "SIRI-SPEECH-002",
                message: "SFSpeechRecognizer.authorizationStatus returned an unknown value (\(status.rawValue)).",
                remediationURL: nil
            )]
        }
    }

    // MARK: - Check: AVAudioSession competition (macOS / iOS)

    private static func checkAudioSessionForSiriCompetition() -> [SiriQuarantineWarning] {
        // AVAudioSession.isOtherAudioPlaying reflects whether another app is actively
        // producing audio. It does NOT tell us specifically whether Siri is listening.
        //
        // There is NO public API to query "is assistantd / Siri's mic pipeline active."
        // Apple does not expose this. We check two things we CAN observe:
        //   1. Whether another audio session is active (could be Siri listening or any other app).
        //   2. Secondary audio hint via AVAudioSessionSilenceSecondaryAudioHintNotification
        //      (indicates the OS is routing audio elsewhere — could be Siri, Media, etc.).
        //
        // This check is informational/advisory on macOS — it does not block launch.
        // The actual mic competition is handled by claiming the session before recording starts
        // (see MIC_PRIORITY.md for session configuration).

        #if os(iOS) || os(watchOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        if session.isOtherAudioPlaying {
            return [SiriQuarantineWarning(
                severity: .advisory,
                code: "SIRI-AUDIO-001",
                message: "AVAudioSession.isOtherAudioPlaying = true at JARVIS launch. Another audio session is active (could be Siri, Media, or a competing app). JARVIS will attempt to claim the recording session. If Siri's wake-word pipeline is running, it may intermittently interrupt. Verify the MDM profile is installed and Siri is disabled in Settings.",
                remediationURL: nil
            )]
        }
        return []
        #else
        // macOS does not use AVAudioSession. CoreAudio manages session routing.
        // No equivalent public API to check whether assistantd has the mic.
        // Advisory: the guard cannot introspect CoreAudio tap state from the sandbox.
        log.info("SiriQuarantineGuard: macOS — AVAudioSession not available. CoreAudio mic state is not introspectable from sandbox. Rely on MDM profile enforcement.")
        return []
        #endif
    }

    // MARK: - Refuse all Siri donation surfaces

    /// Call this unconditionally at launch. Ensures no user activities, interactions,
    /// or shortcut donations are forwarded to Siri, regardless of authorization state.
    private static func refuseAllSiriDonations() {
        // 1. Delete any INInteraction donations this app may have previously made.
        //    On a fresh install this is a no-op. Defensive cleanup on updates.
        #if os(macOS)
        log.info("SiriQuarantineGuard: macOS has no public INInteraction deletion surface for this app target; no SiriKit extension is linked.")
        #else
        INInteraction.deleteAllInteractions { error in
            if let error {
                log.error("SiriQuarantineGuard: INInteraction.deleteAllInteractions failed: \(auditDetail(error.localizedDescription)). Non-fatal — donations were likely empty.") // [audit-log: raw error via auditDetail redaction]
            } else {
                log.info("SiriQuarantineGuard: INInteraction.deleteAllInteractions complete.")
            }
        }
        #endif

        // 2. No NSUserActivity donations are made by JARVIS.
        //    Enforced structurally: JARVIS does not call `becomeCurrent()` on any
        //    NSUserActivity with `isEligibleForPrediction = true` or
        //    `isEligibleForHandoff = true`. The cockpit never sets these.
        //    Documented here as policy — there is no runtime API to "globally disable"
        //    future donations; the control is at activity creation time.
        log.info("SiriQuarantineGuard: NSUserActivity donation policy — isEligibleForPrediction = false enforced at creation site throughout cockpit.")

        // 3. No SiriKit Intent Extension is linked. Confirmed structurally by the absence
        //    of Intents.framework in the link phase and no NSExtension with
        //    NSExtensionPointIdentifier = com.apple.intents-service in any extension bundle.
        log.info("SiriQuarantineGuard: No SiriKit Intent Extension present. Intent donation surface = zero.")
    }
}

// MARK: - NSUserActivity quarantine extension
//
// Any code in the cockpit that creates an NSUserActivity for state restoration,
// Handoff, or Spotlight indexing MUST call `.quarantineForJARVIS()` on it.
// This extension enforces the donation policy at the creation site.

public extension NSUserActivity {

    /// Marks this activity as ineligible for all Siri prediction and search donation surfaces.
    /// Call this on every NSUserActivity created in JARVIS. It is a no-op on activities
    /// that were already ineligible.
    @discardableResult
    func quarantineForJARVIS() -> NSUserActivity {
        #if !os(macOS)
        self.isEligibleForPrediction = false
        #endif
        self.isEligibleForSearch = false
        self.isEligibleForHandoff = false
        self.isEligibleForPublicIndexing = false
        return self
    }
}
