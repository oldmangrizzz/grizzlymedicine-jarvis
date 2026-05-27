import Foundation

// JARVISAuditArmer LaunchDaemon entry — V4R R11l α.3.1.
//
// Sets up an NSXPCListener on the Mach service name
// `ai.realjarvis.audit.armer`, vets incoming connections, and exports the
// JARVISAuditArmer instance per connection. The Mach service name is
// matched against the LaunchDaemon plist's MachServices key.
//
// Connection vetting: peer EUID is read from the connection's
// effectiveUserIdentifier. The exported JARVISAuditArmer instance is
// constructed with that EUID — every path-validation check is performed
// against THIS peer's audit-root, regardless of any future audit_token
// drift on the same connection.
//
// Lifetime: dispatchMain() — daemonized, run-loop owned by launchd.

final class JARVISAuditArmerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // R11l α.3.1 — bind peer EUID at connection-accept time.
        let peerEUID = newConnection.effectiveUserIdentifier

        // Refuse root → root self-talk (no useful invariant covered) and
        // refuse nobody (uid 4294967294, -2 → unauthenticated).
        if peerEUID == 0 || peerEUID == uid_t.max - 1 {
            return false
        }

        let armer = JARVISAuditArmer(peerEUID: peerEUID)

        let interface = NSXPCInterface(with: SFAppendArmerXPCProtocol.self)
        newConnection.exportedInterface = interface
        newConnection.exportedObject = armer
        newConnection.resume()
        return true
    }
}

let delegate = JARVISAuditArmerListenerDelegate()
let listener = NSXPCListener(machServiceName: sfAppendArmerMachServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
