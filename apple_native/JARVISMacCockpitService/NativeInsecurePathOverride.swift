// NativeInsecurePathOverride — V4R R11d F-C02
//
// Single chokepoint for all identity/security path env overrides
// (JARVIS_HOME, JARVIS_AUDIT_ROOT, JARVIS_BIRTH_CERT_PATH,
// JARVIS_COLD_ROOT_PIN_FILE, JARVIS_HTTP_*_STORE, JARVIS_ENV_FILE).
//
// All such overrides are honored ONLY in builds compiled with
// `-D JARVIS_INSECURE_PATHS` AND `DEBUG`. The SwiftPM Package.swift
// scopes this to debug configuration; release builds compile out
// the env-read branch entirely (the helper returns the canonical
// path unconditionally).
//
// Every consumption of an override (in debug+flag builds) fires
// a one-shot `insecure_path_override_active` audit event so any
// boot that used a non-canonical identity path leaves a trace in
// the audit log. The emission is one-shot per (envVar, path) pair
// to prevent a storm when audit-module env reads recurse.
//
// Audit modules themselves (NativeSecurityAudit,
// NativeUpstreamErrorAudit) MUST NOT call this helper for their
// own root-dir env read — that would recurse infinitely. They use
// the inline #if DEBUG && JARVIS_INSECURE_PATHS pattern directly,
// without audit emission, and rely on a sibling-module emission
// (e.g. BC verifier's pin-missing record) to leave the override
// trace.

import Foundation

enum NativeInsecurePathOverride {
    private static let lock = NSLock()
    // Mutable state guarded by `lock`. `nonisolated(unsafe)` is the documented
    // escape hatch for "synchronization provided externally" — see
    // SE-0412. Not a suppression of a real concurrency hazard; the lock
    // ownership is total for both read and write paths.
    nonisolated(unsafe) private static var emittedKeys: Set<String> = []

    /// Resolve an env-overridable path. In debug+JARVIS_INSECURE_PATHS, returns
    /// the env value if present and non-empty (with tilde expansion + a one-shot
    /// audit emission). Otherwise returns `canonicalPath`.
    ///
    /// `envVar`: the env variable name (e.g. "JARVIS_BIRTH_CERT_PATH").
    /// `canonicalPath`: the unconditional fallback (typically "~/.jarvis/...").
    /// `env`: caller's snapshot of process env (testable seam).
    /// `emitAudit`: when true (default), fires `insecure_path_override_active`
    ///              on first consumption per (envVar, value) pair.
    static func resolve(
        envVar: String,
        canonicalPath: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        emitAudit: Bool = true
    ) -> String {
        #if DEBUG && JARVIS_INSECURE_PATHS
        if let raw = env[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            if emitAudit { emitOnce(envVar: envVar, value: expanded) }
            return expanded
        }
        #endif
        return NSString(string: canonicalPath).expandingTildeInPath
    }

    private static func emitOnce(envVar: String, value: String) {
        let key = envVar + "=" + value
        lock.lock()
        let alreadyEmitted = emittedKeys.contains(key)
        if !alreadyEmitted { emittedKeys.insert(key) }
        lock.unlock()
        guard !alreadyEmitted else { return }
        do {
            try NativeSecurityAudit.record(
                "insecure_path_override_active",
                fields: ["var": envVar, "value": value]
            )
        } catch {
            fputs("JARVIS audit write failed for insecure_path_override_active: \(error)\n", stderr)
        }
    }

    /// Test-only reset of the one-shot emission set. Only available in debug+flag.
    static func resetEmissionsForTest() {
        #if DEBUG && JARVIS_INSECURE_PATHS
        lock.lock()
        emittedKeys.removeAll()
        lock.unlock()
        #endif
    }
}
