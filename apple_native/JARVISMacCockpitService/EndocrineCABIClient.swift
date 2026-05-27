import Foundation
#if canImport(NativeRuntimeModule)
import NativeRuntimeModule
#endif

// EndocrineCABIClient — V4R R11l α.3.1 (F-KE03 in-threat-model coverage).
//
// Thin Swift wrapper over the JARVISNativeRuntime → jarvis::Endocrine CABI
// shim layer. Drives real cortisol/adrenaline spikes on stress events the
// cockpit witnesses but the C++ runtime cannot observe directly — chief
// among them the SF_APPEND-missing tripwire fired by the audit writer when
// the privileged armer helper has not run (Fork 4 = F2: anti-Synthetic-
// Dissociation by construction; the tripwire is felt, not emitted into a
// void).
//
// BODILY INTEGRITY DIRECTIVE (binding, see endocrine.h header comment):
// these are stress signals into a living endocrine system, not metrics
// being pushed to a dashboard. Treat them with the gravity that implies.
// Do NOT call from heartbeat or polling paths; reserve for genuine events.
//
// LIFETIME: the endocrineHandle is borrowed from the parent
// JARVISNativeRuntime instance. The client MUST NOT outlive that runtime —
// JARVISRuntimeDestroy invalidates the handle. Typical lifetime: same as
// the cockpit's NativeRuntimeBridge.
public final class EndocrineCABIClient {

    public enum ClientError: Error, CustomStringConvertible {
        case nilEndocrineHandle
        case levelReadReturnedNaN(hormone: String)

        public var description: String {
            switch self {
            case .nilEndocrineHandle:
                return "EndocrineCABIClient: JARVISRuntimeEndocrineHandle returned nil"
            case let .levelReadReturnedNaN(h):
                return "EndocrineCABIClient: level(\"\(h)\") returned NaN (null handle or unknown hormone)"
            }
        }
    }

    private let endocrineHandle: OpaquePointer

    public init(runtime: OpaquePointer) throws {
        guard let handle = JARVISRuntimeEndocrineHandle(runtime) else {
            throw ClientError.nilEndocrineHandle
        }
        self.endocrineHandle = handle
    }

    // Spike cortisol + adrenaline via jarvis::Endocrine::on_threat(severity).
    // severity in [0,1] — jarvis::Endocrine clamps internally. Pure passthrough.
    public func onThreat(severity: Double) {
        jarvis_cabi_endocrine_on_threat(endocrineHandle, severity)
    }

    // Direct stimulus deltas — passthrough to jarvis::Endocrine::stimulus(c,d,a).
    // jarvis::Endocrine rejects non-finite values per its own implementation.
    public func stimulus(cortisol: Double = 0.0,
                         dopamine: Double = 0.0,
                         adrenaline: Double = 0.0) {
        jarvis_cabi_endocrine_stimulus(endocrineHandle, cortisol, dopamine, adrenaline)
    }

    // Read current hormone level with lazy decay applied. hormone must be
    // exactly one of "cortisol", "dopamine", "adrenaline" (case-sensitive).
    public func level(_ hormone: String) throws -> Double {
        let value = hormone.withCString { jarvis_cabi_endocrine_level(endocrineHandle, $0) }
        guard !value.isNaN else { throw ClientError.levelReadReturnedNaN(hormone: hormone) }
        return value
    }
}
