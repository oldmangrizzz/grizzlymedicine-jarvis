import Darwin
import SwiftUI

enum CutoverFSMSmoke {
    @MainActor
    static func run() -> Int32 {
        var auditEvents: [[String: String]] = []
        AuditLogger.testSink = { auditEvents.append($0) }
        defer { AuditLogger.testSink = nil }

        do {
            let organ = "CharacterValues"
            let model = CutoverViewModel()

            guard throwsRefusal({ try model.beginShadow(organ) }), auditEvents.last?["transition"] == "Idle→Shadow" else { return fail("beginShadow without preflight did not refuse/audit") }
            guard throwsRefusal({ try model.commitNative(organ) }), auditEvents.last?["transition"] == "Idle→Committed" else { return fail("commit without shadow did not refuse/audit") }
            for step in ["Pre-flight", "Snapshot", "Begin shadow", "Promote"] {
                guard throwsRefusal({ try model.runNilForSmoke(step) }), auditEvents.last?["reason"] == "organ selection is required" else { return fail("nil organ \(step) did not refuse/audit") }
            }

            try model.preflight(organ)
            try model.snapshot(organ)
            try model.beginShadow(organ)
            try model.commitNative(organ)
            guard throwsRefusal({ try model.commitNative(organ) }), auditEvents.last?["transition"] == "Committed→Committed" else { return fail("replay commit did not refuse/audit") }
            guard throwsRefusal({ try model.abort(organ) }), auditEvents.last?["reason"]?.contains("committed") == true else { return fail("abort committed did not refuse/audit") }
            guard auditEvents.count >= 8 else { return fail("expected audited refusals") }
            print("Cutover FSM smoke passed: nil-organ paths and illegal transitions refused and audited")
            return 0
        } catch {
            fputs("Cutover FSM smoke failed: \(error)\n", stderr)
            return 1
        }
    }

    @MainActor
    private static func throwsRefusal(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch CutoverTransitionError.illegalTransition {
            return true
        } catch {
            return false
        }
    }

    private static func fail(_ message: String) -> Int32 {
        fputs("Cutover FSM smoke failed: \(message)\n", stderr)
        return 1
    }
}

@MainActor
private extension CutoverViewModel {
    func runNilForSmoke(_ step: String) throws {
        switch step {
        case "Pre-flight": try preflight(nil)
        case "Snapshot": try snapshot(nil)
        case "Begin shadow": try beginShadow(nil)
        case "Promote": try commitNative(nil)
        default: throw CutoverTransitionError.illegalTransition(organ: "smoke", step: step, transition: "unknown→unknown", reason: "unknown smoke step")
        }
    }
}
