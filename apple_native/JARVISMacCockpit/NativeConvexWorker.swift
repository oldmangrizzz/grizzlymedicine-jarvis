import Combine
import Foundation

@MainActor
final class NativeConvexWorkerService: ObservableObject {
    @Published private(set) var statusLine = "Convex worker idle"
    @Published private(set) var detailLine = "Not started."
    @Published private(set) var isEnabled = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var processedCount = 0
    @Published private(set) var lastSyncText = "never"

    private let client: NativeConvexClient
    private let configuration: NativeConvexConfiguration
    private weak var runtime: NativeRuntimeBridge?
    private var modelClient: NativeModelClient?
    private var loopTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(client: NativeConvexClient = NativeConvexClient()) {
        self.client = client
        self.configuration = client.configuration
    }

    deinit {
        loopTask?.cancel()
    }

    func start(runtime: NativeRuntimeBridge?, modelClient: NativeModelClient) {
        guard loopTask == nil else {
            return
        }
        guard configuration.enabled else {
            isEnabled = false
            statusLine = "Convex worker disabled"
            detailLine = configuration.disabledReason
            return
        }
        guard let runtime else {
            isEnabled = false
            statusLine = "Convex worker blocked"
            detailLine = "Native runtime is unavailable; control requests will not be claimed."
            return
        }
        self.runtime = runtime
        self.modelClient = modelClient
        isEnabled = true
        statusLine = "Convex worker starting"
        detailLine = "Publishing native runtime state and skill catalog."
        loopTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        if isEnabled {
            statusLine = "Convex worker stopped"
            detailLine = "Polling task cancelled."
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let sleepSeconds: Double
            do {
                try await syncOnce()
                consecutiveFailures = 0
                statusLine = "Convex worker synced"
                detailLine = pendingCount == 0
                    ? "State/catalog published; no pending control requests."
                    : "Processed pending control batch."
                sleepSeconds = configuration.pollSeconds
            } catch {
                consecutiveFailures += 1
                let backoff = backoffDelay(forFailureCount: consecutiveFailures)
                statusLine = "Convex worker error"
                detailLine = "\(operatorMessage(.networkRefused)) Retrying in \(String(format: "%.1f", backoff))s."
                JARVISLog.warn(subsystem: "convex", event: "poll_backoff", fields: [
                    "failure_count": String(consecutiveFailures),
                    "delay_seconds": String(format: "%.3f", backoff),
                    "error": auditDetail(error.localizedDescription), // [audit-log: raw error via auditDetail redaction]
                ])
                try? await publishWorkerState(phase: "error", detail: detailLine)
                sleepSeconds = backoff
            }
            lastSyncText = Self.timeFormatter.string(from: Date())
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

    private func backoffDelay(forFailureCount failureCount: Int) -> Double {
        let cappedExponent = min(max(failureCount - 1, 0), 8)
        let exponential = configuration.pollSeconds * pow(2.0, Double(cappedExponent))
        let capped = min(30.0, max(configuration.pollSeconds, exponential))
        let jitter = Double.random(in: 0...(capped * 0.20))
        return min(30.0, capped + jitter)
    }

    private func syncOnce() async throws {
        guard let runtime, let modelClient else {
            throw NativeConvexWorkerError.runtimeUnavailable
        }

        let stateValue = try runtime.stateValue()
        _ = try await client.publishState(key: "runtime", source: configuration.source, payload: stateValue)
        let catalog = try runtime.skillCatalog()
        _ = try await client.publishSkillCatalog(catalog)
        try await publishWorkerState(phase: "published", detail: "Native runtime state and skill catalog published.")

        let pending = try await client.pendingControlRequests(limit: configuration.batchLimit)
        pendingCount = pending.count
        for request in pending {
            guard !request.requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard try await client.claimControlRequest(requestId: request.requestId, runner: configuration.runner) != nil else {
                continue
            }
            let result = await handleControlRequest(request, runtime: runtime, modelClient: modelClient)
            _ = try await client.completeControlRequest(requestId: request.requestId, result: result)
            _ = try? await client.publishState(
                key: "latest_skill_result",
                source: configuration.source,
                payload: result.output
            )
            processedCount += 1
        }
        try await publishWorkerState(phase: "synced", detail: "Processed \(pending.count) pending request(s).")
    }

    private func handleControlRequest(
        _ request: NativeControlRequest,
        runtime: NativeRuntimeBridge,
        modelClient: NativeModelClient
    ) async -> NativeControlResult {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch name {
            case "jarvis_turn":
                return try await handleJarvisTurn(request, runtime: runtime, modelClient: modelClient)
            default:
                return try dispatchNativeSkill(request, name: name, runtime: runtime)
            }
        } catch {
            return errorResult(request: request, skill: name, error: error, runtime: runtime)
        }
    }

    private func handleJarvisTurn(
        _ request: NativeControlRequest,
        runtime: NativeRuntimeBridge,
        modelClient: NativeModelClient
    ) async throws -> NativeControlResult {
        guard let text = stringArg("text", in: request.objectArgs), !text.isEmpty else {
            return refusedResult(
                request: request,
                skill: "jarvis_turn",
                reason: "jarvis_turn requires args.text.",
                authorizationRequired: false,
                runtime: runtime
            )
        }
        let prepared = try runtime.prepareTurn(text)
        let modelReply = try await modelClient.complete(messages: prepared.messages, requestedModel: prepared.model)
        let committed = try runtime.commitTurn(text: text, reply: modelReply.text, model: modelReply.model)
        let payload: NativeJSONValue = .object([
            "reply": .string(committed.reply),
            "model": .string(committed.model),
            "state": try NativeJSONValue.fromEncodable(committed.state),
        ])
        return okResult(request: request, skill: "jarvis_turn", payload: payload, runtime: runtime)
    }

    private func dispatchNativeSkill(
        _ request: NativeControlRequest,
        name: String,
        runtime: NativeRuntimeBridge
    ) throws -> NativeControlResult {
        let argsJSON = try argsJSONString(request.args ?? .object([:]))
        let dispatch = try runtime.dispatchSkill(name: name, argsJSON: argsJSON)
        let object = dispatch.objectValue ?? [:]
        let ok = object["ok"]?.boolValue ?? false
        let blocked = object["blocked"]?.boolValue ?? false
        let refused = object["refused"]?.boolValue ?? false
        let authorizationRequired = object["authorization_required"]?.boolValue ?? object["authorizationRequired"]?.boolValue ?? false
        let reason = object["reason"]?.stringValue
        let error = object["error"]?.stringValue
        return NativeControlResult(
            ok: ok,
            skill: object["skill"]?.stringValue ?? (name.isEmpty ? "unknown" : name),
            output: .object(["native_hasp_receipt": dispatch]),
            refused: refused || blocked || authorizationRequired,
            reason: reason,
            error: ok ? nil : (error ?? reason),
            authorizationRequired: authorizationRequired
        )
    }

    private func blockedSkillResult(
        request: NativeControlRequest,
        skill name: String,
        runtime: NativeRuntimeBridge
    ) -> NativeControlResult {
        let catalog = try? runtime.skillCatalog()
        let definition = catalog?.skills.first { $0.name == name }
        let authorizationRequired = definition.map { ["SENSITIVE", "DESTRUCTIVE"].contains($0.risk) } ?? false
        let reason: String
        if let definition {
            if definition.risk == "PROHIBITED" || definition.status == "refused" {
                reason = "Prohibited action refused by native skill registry: \(definition.description)"
            } else if authorizationRequired {
                reason = "Queued Convex control cannot carry private authorization; \(definition.name) remains native-gated."
            } else {
                reason = "Native adapter blocked for \(definition.name): \(definition.description)"
            }
        } else {
            reason = "Unavailable native skill/action '\(name)' has no Swift/C++ adapter."
        }
        return refusedResult(
            request: request,
            skill: name.isEmpty ? "unknown" : name,
            reason: reason,
            authorizationRequired: authorizationRequired,
            runtime: runtime
        )
    }

    private func okResult(
        request: NativeControlRequest,
        skill: String,
        payload: NativeJSONValue,
        runtime: NativeRuntimeBridge
    ) -> NativeControlResult {
        let receipt = auditReceipt(
            request: request,
            skill: skill,
            status: "done",
            ok: true,
            refused: false,
            blocked: false,
            reason: nil,
            error: nil,
            authorizationRequired: false,
            runtime: runtime
        )
        return NativeControlResult(
            ok: true,
            skill: skill,
            output: .object(["output": payload, "audit_receipt": receipt]),
            refused: false,
            reason: nil,
            error: nil,
            authorizationRequired: false
        )
    }

    private func refusedResult(
        request: NativeControlRequest,
        skill: String,
        reason: String,
        authorizationRequired: Bool,
        runtime: NativeRuntimeBridge
    ) -> NativeControlResult {
        let receipt = auditReceipt(
            request: request,
            skill: skill,
            status: "refused",
            ok: false,
            refused: true,
            blocked: true,
            reason: reason,
            error: nil,
            authorizationRequired: authorizationRequired,
            runtime: runtime
        )
        return NativeControlResult(
            ok: false,
            skill: skill,
            output: .object(["audit_receipt": receipt]),
            refused: true,
            reason: reason,
            error: nil,
            authorizationRequired: authorizationRequired
        )
    }

    private func errorResult(
        request: NativeControlRequest,
        skill: String,
        error: Error,
        runtime: NativeRuntimeBridge
    ) -> NativeControlResult {
        let message = auditDetail(error.localizedDescription) // [audit-log: raw error via auditDetail redaction; not surfaced in UI]
        let receipt = auditReceipt(
            request: request,
            skill: skill,
            status: "error",
            ok: false,
            refused: false,
            blocked: true,
            reason: nil,
            error: message,
            authorizationRequired: false,
            runtime: runtime
        )
        return NativeControlResult(
            ok: false,
            skill: skill,
            output: .object(["audit_receipt": receipt]),
            refused: false,
            reason: nil,
            error: message,
            authorizationRequired: false
        )
    }

    private func auditReceipt(
        request: NativeControlRequest,
        skill: String,
        status: String,
        ok: Bool,
        refused: Bool,
        blocked: Bool,
        reason: String?,
        error: String?,
        authorizationRequired: Bool,
        runtime: NativeRuntimeBridge
    ) -> NativeJSONValue {
        let state = (try? runtime.stateValue()) ?? .object([:])
        var receipt: [String: NativeJSONValue] = [
            "receipt_type": .string("native_control_completion"),
            "request_id": .string(request.requestId),
            "requested_by": .string(request.requestedBy),
            "skill": .string(skill),
            "status": .string(status),
            "ok": .bool(ok),
            "refused": .bool(refused),
            "blocked": .bool(blocked),
            "authorization_required": .bool(authorizationRequired),
            "runner": .string(configuration.runner),
            "source": .string(configuration.source),
            "runtime": .string("native-swift-cpp"),
            "python_beta_path": .bool(false),
            "audit_at": .number(Date().timeIntervalSince1970),
            "memory": state["memory"] ?? fallbackMemoryState,
            "provenance": state["provenance"] ?? fallbackProvenance(operation: "control_completion"),
        ]
        if let deviceId = request.deviceId, !deviceId.isEmpty {
            receipt["device_id"] = .string(deviceId)
        }
        if let authorizationIntent = request.authorizationIntent, !authorizationIntent.isEmpty {
            receipt["authorization_intent"] = .string(authorizationIntent)
        }
        if let reason, !reason.isEmpty {
            receipt["reason"] = .string(reason)
        }
        if let error, !error.isEmpty {
            receipt["error"] = .string(error)
        }
        return .object(receipt)
    }

    private func publishWorkerState(phase: String, detail: String) async throws {
        let payload: NativeJSONValue = .object([
            "enabled": .bool(configuration.enabled),
            "phase": .string(phase),
            "detail": .string(detail),
            "runner": .string(configuration.runner),
            "source": .string(configuration.source),
            "pending_count": .number(Double(pendingCount)),
            "processed_count": .number(Double(processedCount)),
            "poll_seconds": .number(configuration.pollSeconds),
            "url_configured": .bool(configuration.deploymentURL != nil),
            "token_configured": .bool(!configuration.token.isEmpty),
            "runtime": .string("native-swift-cpp"),
            "python_beta_path": .bool(false),
            "observable_signal_language": .bool(true),
            "person_memory_separation": .bool(true),
            "updated_at": .number(Date().timeIntervalSince1970),
        ])
        _ = try await client.publishState(key: "native_worker", source: configuration.source, payload: payload)
    }

    private func stringArg(_ key: String, in args: [String: NativeJSONValue]) -> String? {
        switch args[key] {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }

    private func argsJSONString(_ args: NativeJSONValue) throws -> String {
        let data = try JSONEncoder().encode(args)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NativeRuntimeError.invalidUTF8
        }
        return text
    }

    private var fallbackMemoryState: NativeJSONValue {
        .object([
            "consent_boundary": .string("explicit_consent_per_person"),
            "person_memory_separation": .bool(true),
            "observable_signal_language": .bool(true),
        ])
    }

    private func fallbackProvenance(operation: String) -> NativeJSONValue {
        .object([
            "source": .string(configuration.source),
            "actor": .string(configuration.runner),
            "runtime": .string("native-swift-cpp"),
            "operation": .string(operation),
            "python_beta_path": .bool(false),
        ])
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

enum NativeConvexWorkerError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Native runtime is unavailable."
        }
    }
}
