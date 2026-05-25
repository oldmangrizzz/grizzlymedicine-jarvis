import Foundation
#if canImport(NativeRuntimeModule)
import NativeRuntimeModule
#endif

final class NativeRuntimeBridge {
    private let handle: OpaquePointer
    private let decoder = JSONDecoder()

    init() throws {
        NativeEnvironment.applyToProcess()
        guard let created = JARVISRuntimeCreate() else {
            throw NativeRuntimeError.creationFailed
        }
        guard JARVISRuntimeMount(created) == 1 else {
            JARVISRuntimeDestroy(created)
            throw NativeRuntimeError.mountFailed
        }
        handle = created
    }

    deinit {
        _ = JARVISRuntimeUnmount(handle)
        JARVISRuntimeDestroy(handle)
    }

    func state() throws -> NativeRuntimeState {
        try decode(JARVISRuntimeStateJSON(handle))
    }

    func stateValue() throws -> NativeJSONValue {
        try decodeValue(JARVISRuntimeStateJSON(handle))
    }

    func skillCatalog() throws -> NativeSkillCatalog {
        try decode(JARVISRuntimeSkillCatalogJSON(handle))
    }

    func skillCatalogValue() throws -> NativeJSONValue {
        try decodeValue(JARVISRuntimeSkillCatalogJSON(handle))
    }

    func skillCatalogObject() throws -> [String: Any] {
        try decodeObject(JARVISRuntimeSkillCatalogJSON(handle))
    }

    func dispatchSkill(name: String, argsJSON: String = "{}", authorization: String = "") throws -> NativeJSONValue {
        try name.withCString { cName in
            try argsJSON.withCString { cArgs in
                try authorization.withCString { cAuthorization in
                    try decodeValue(JARVISRuntimeDispatchSkillJSON(handle, cName, cArgs, cAuthorization))
                }
            }
        }
    }

    func auditValue() throws -> NativeJSONValue {
        try decodeValue(JARVISRuntimeAuditJSON(handle))
    }

    func auditLog() throws -> NativeAuditLog {
        try decode(JARVISRuntimeAuditJSON(handle))
    }

    func uiSpec() throws -> JARVISUISpec {
        let response: NativeUISpecResponse = try decode(JARVISRuntimeUISpecJSON(handle))
        return response.uiSpec
    }

    func voiceStatus() throws -> NativeVoiceStatus {
        try decode(JARVISRuntimeVoiceStatusJSON(handle))
    }

    func speechPolicy(for text: String) throws -> NativeSpeechResponse {
        try text.withCString { cText in
            try decode(JARVISRuntimeSpeechJSON(handle, cText))
        }
    }

    func prepareTurn(_ text: String) throws -> NativePreparedTurn {
        try text.withCString { cText in
            try decode(JARVISRuntimePrepareTurnJSON(handle, cText))
        }
    }

    func commitTurn(text: String, reply: String, model: String) throws -> NativeCommittedTurn {
        try text.withCString { cText in
            try reply.withCString { cReply in
                try model.withCString { cModel in
                    try decode(JARVISRuntimeCommitTurnJSON(handle, cText, cReply, cModel))
                }
            }
        }
    }

    private func decode<T: Decodable>(_ raw: UnsafeMutablePointer<CChar>?) throws -> T {
        let data = try data(from: raw)
        if let failure = try? decoder.decode(NativeRuntimeFailure.self, from: data),
           failure.ok == false,
           failure.code == nil {
            throw NativeRuntimeError.runtime(failure.error)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func decodeValue(_ raw: UnsafeMutablePointer<CChar>?) throws -> NativeJSONValue {
        let data = try data(from: raw)
        if let failure = try? decoder.decode(NativeRuntimeFailure.self, from: data),
           failure.ok == false,
           failure.code == nil {
            throw NativeRuntimeError.runtime(failure.error)
        }
        return try decoder.decode(NativeJSONValue.self, from: data)
    }

    private func decodeObject(_ raw: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let data = try data(from: raw)
        if let failure = try? decoder.decode(NativeRuntimeFailure.self, from: data),
           failure.ok == false,
           failure.code == nil {
            throw NativeRuntimeError.runtime(failure.error)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeRuntimeError.runtime("Native runtime response was not a JSON object.")
        }
        return object
    }

    private func data(from raw: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let raw else {
            throw NativeRuntimeError.emptyNativeResponse
        }
        defer { JARVISRuntimeFreeString(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else {
            throw NativeRuntimeError.invalidUTF8
        }
        return data
    }
}

enum NativeRuntimeError: LocalizedError {
    case creationFailed
    case mountFailed
    case emptyNativeResponse
    case invalidUTF8
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "The native C++ runtime could not be created."
        case .mountFailed:
            return "The native C++ runtime was created but could not be mounted."
        case .emptyNativeResponse:
            return "The native runtime returned no response."
        case .invalidUTF8:
            return "The native runtime returned invalid UTF-8."
        case .runtime(let message):
            return message
        }
    }
}

struct NativeRuntimeFailure: Codable {
    let ok: Bool
    let error: String
    let code: String?
}

struct NativePreparedTurn: Codable {
    let ok: Bool
    let model: String
    let messages: [NativeChatMessage]
    let state: NativeRuntimeState
}

struct NativeCommittedTurn: Codable {
    let ok: Bool
    let reply: String
    let model: String
    let driftToPrototype: Double
    let ethicsConflict: Bool
    let state: NativeRuntimeState

    enum CodingKeys: String, CodingKey {
        case ok
        case reply
        case model
        case driftToPrototype = "drift_to_prototype"
        case ethicsConflict = "ethics_conflict"
        case state
    }
}

struct NativeRuntimeState: Codable {
    let endocrine: [String: Double]
    let ecTone: Double
    let field: [NativeFieldSignal]
    let historyCount: Int
    let auditCount: Int?
    let mounted: Bool
    let mountedAt: Double?
    let pheromind: NativePheromindState?
    let swarm: NativeSwarmState?
    let cusum: NativeCUSUMState?
    let identityContinuity: NativeIdentityContinuityState?
    let runtime: String
    let pythonBetaPath: Bool
    let skillRegistry: NativeSkillRegistrySummary?
    let voice: NativeVoiceStatus?
    let memory: NativeMemoryState?
    let provenance: NativeProvenanceState?

    enum CodingKeys: String, CodingKey {
        case endocrine
        case ecTone = "ec_tone"
        case field
        case historyCount = "history_count"
        case auditCount = "audit_count"
        case mounted
        case mountedAt = "mounted_at"
        case pheromind
        case swarm
        case cusum
        case identityContinuity = "identity_continuity"
        case runtime
        case pythonBetaPath = "python_beta_path"
        case skillRegistry = "skill_registry"
        case voice
        case memory
        case provenance
    }
}


struct NativePheromindState: Codable, Equatable {
    let volatility: Double
    let signalCount: Int?

    enum CodingKeys: String, CodingKey {
        case volatility
        case signalCount = "signal_count"
    }
}

struct NativeSwarmState: Codable, Equatable {
    let activity: Double
    let presentOrgans: Int
    let mode: String

    enum CodingKeys: String, CodingKey {
        case activity
        case presentOrgans = "active_agents"
        case mode
    }
}

struct NativeCUSUMState: Codable, Equatable {
    let driftScore: Double
    let status: String

    enum CodingKeys: String, CodingKey {
        case driftScore = "drift_score"
        case status
    }
}

struct NativeIdentityContinuityState: Codable, Equatable {
    let ok: Bool
    let indicator: String
    let `operator`: String
}

struct NativeAuditLog: Codable, Equatable {
    let ok: Bool
    let source: String
    let runtime: String
    let pythonBetaPath: Bool
    let count: Int
    let entries: [NativeAuditEntry]

    enum CodingKeys: String, CodingKey {
        case ok
        case source
        case runtime
        case pythonBetaPath = "python_beta_path"
        case count
        case entries
    }
}

struct NativeAuditEntry: Codable, Equatable, Identifiable {
    let id: UInt64
    let observedAt: Double
    let skill: String
    let risk: String
    let status: String
    let decision: String
    let ok: Bool
    let authorizationSupplied: Bool
    let authorizationConfigured: Bool
    let argsPreview: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case id
        case observedAt = "observed_at"
        case skill
        case risk
        case status
        case decision
        case ok
        case authorizationSupplied = "authorization_supplied"
        case authorizationConfigured = "authorization_configured"
        case argsPreview = "args_preview"
        case reason
    }
}

struct NativeFieldSignal: Codable, Identifiable {
    var id: String { "\(kind):\(topic)" }
    let kind: String
    let topic: String
    let strength: Double
    let depositors: Int
}

struct NativeChatMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct NativeSkillCatalog: Codable {
    let ok: Bool
    let registry: NativeSkillRegistrySummary
    let skills: [NativeRuntimeSkill]
}

struct NativeSkillRegistrySummary: Codable {
    let source: String
    let pythonBetaPath: Bool
    let execution: String
    let count: Int
    let risks: [String]

    enum CodingKeys: String, CodingKey {
        case source
        case pythonBetaPath = "python_beta_path"
        case execution
        case count
        case risks
    }
}

struct NativeRuntimeSkill: Codable, Identifiable {
    var id: String { name }
    let name: String
    let risk: String
    let status: String
    let implemented: Bool?
    let description: String
}

struct NativeMemoryState: Codable, Equatable {
    let consentBoundary: String
    let personMemorySeparation: Bool
    let observableSignalLanguage: Bool
    let clinicalLabeling: Bool?
    let controlWorkerScope: String?
    let substrate: String?
    let runtimeStore: String?
    let pythonBetaPath: Bool?
    let holographIntegrated: Bool?
    let writer: String?
    let reader: String?
    let provenanceAxis: Bool?
    let originVsReal: Bool?
    let operatorOwnedValues: Bool?
    let modelClaimsQuarantined: Bool?
    let demoteNotDelete: Bool?
    let abstainBelowFloor: Bool?
    let chargeAxis: String?
    let beliefCount: Int?
    let activeBeliefs: Int?
    let quarantinedBeliefs: Int?
    let originBeliefs: Int?
    let operatorValues: Int?
    let storageError: String?
    let scopes: [NativeMemoryScope]
    let boundaryNote: String?

    enum CodingKeys: String, CodingKey {
        case consentBoundary = "consent_boundary"
        case personMemorySeparation = "person_memory_separation"
        case observableSignalLanguage = "observable_signal_language"
        case clinicalLabeling = "clinical_labeling"
        case controlWorkerScope = "control_worker_scope"
        case substrate
        case runtimeStore = "runtime_store"
        case pythonBetaPath = "python_beta_path"
        case holographIntegrated = "holograph_integrated"
        case writer
        case reader
        case provenanceAxis = "provenance_axis"
        case originVsReal = "origin_vs_real"
        case operatorOwnedValues = "operator_owned_values"
        case modelClaimsQuarantined = "model_claims_quarantined"
        case demoteNotDelete = "demote_not_delete"
        case abstainBelowFloor = "abstain_below_floor"
        case chargeAxis = "charge_axis"
        case beliefCount = "belief_count"
        case activeBeliefs = "active_beliefs"
        case quarantinedBeliefs = "quarantined_beliefs"
        case originBeliefs = "origin_beliefs"
        case operatorValues = "operator_values"
        case storageError = "storage_error"
        case scopes
        case boundaryNote = "boundary_note"
    }
}

struct NativeMemoryScope: Codable, Equatable, Identifiable {
    var id: String { memoryScopeId }

    let personId: String
    let memoryScopeId: String
    let consentBasis: String
    let allowedSources: [String]
    let retention: String
    let provenanceRequired: Bool

    enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case memoryScopeId = "memory_scope_id"
        case consentBasis = "consent_basis"
        case allowedSources = "allowed_sources"
        case retention
        case provenanceRequired = "provenance_required"
    }
}

struct NativeProvenanceState: Codable, Equatable {
    let source: String
    let actor: String
    let runtime: String
    let operation: String
    let observedAt: Double
    let pythonBetaPath: Bool
    let evidence: String

    enum CodingKeys: String, CodingKey {
        case source
        case actor
        case runtime
        case operation
        case observedAt = "observed_at"
        case pythonBetaPath = "python_beta_path"
        case evidence
    }
}

struct NativeVoiceStatus: Codable, Equatable {
    let ok: Bool
    let available: Bool
    let safeToSpeak: Bool
    let spoken: Bool
    let code: String
    let reason: String
    let runtime: String
    let pythonBetaPath: Bool
    let backendKind: String
    let backend: String
    let voice: String
    let voiceConfirmed: Bool
    let endpointConfigured: Bool
    let missing: [String]
    let fallbackPolicy: String
    let wrongVoiceFallbackAllowed: Bool
    let systemVoiceFallbackAllowed: Bool
    let nativeSystemVoiceAllowed: Bool
    let pythonTTSAllowed: Bool
    let hardVoiceInvariant: String

    var plainStatus: String {
        available ? "JARVIS native voice ready" : "Voice unavailable — silent by policy"
    }

    var detail: String {
        if available {
            return "\(backend) / \(voice)"
        }
        let missingText = missing.isEmpty ? "native voice backend" : missing.joined(separator: ", ")
        return "\(reason) Missing: \(missingText)."
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case available
        case safeToSpeak = "safe_to_speak"
        case spoken
        case code
        case reason
        case runtime
        case pythonBetaPath = "python_beta_path"
        case backendKind = "backend_kind"
        case backend
        case voice
        case voiceConfirmed = "voice_confirmed"
        case endpointConfigured = "endpoint_configured"
        case missing
        case fallbackPolicy = "fallback_policy"
        case wrongVoiceFallbackAllowed = "wrong_voice_fallback_allowed"
        case systemVoiceFallbackAllowed = "system_voice_fallback_allowed"
        case nativeSystemVoiceAllowed = "native_system_voice_allowed"
        case pythonTTSAllowed = "python_tts_allowed"
        case hardVoiceInvariant = "hard_voice_invariant"
    }
}

struct NativeSpeechResponse: Codable, Equatable {
    let ok: Bool
    let code: String?
    let error: String?
    let reason: String?
    let spoken: Bool
    let backend: String?
    let backendKind: String?
    let contentType: String?
    let audioBase64: String?
    let synthesisSeconds: Double?
    let fallbackPolicy: String?
    let wrongVoiceFallbackAllowed: Bool?
    let systemVoiceFallbackAllowed: Bool?
    let nativeSystemVoiceAllowed: Bool?
    let pythonTTSAllowed: Bool?
    let hardVoiceInvariant: String?
    let status: NativeVoiceStatus?

    var statusLine: String {
        if spoken {
            return "JARVIS spoke through native voice"
        }
        return status?.plainStatus ?? "Voice unavailable — silent by policy"
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case code
        case error
        case reason
        case spoken
        case backend
        case backendKind = "backend_kind"
        case contentType = "content_type"
        case audioBase64 = "audio_base64"
        case synthesisSeconds = "synthesis_seconds"
        case fallbackPolicy = "fallback_policy"
        case wrongVoiceFallbackAllowed = "wrong_voice_fallback_allowed"
        case systemVoiceFallbackAllowed = "system_voice_fallback_allowed"
        case nativeSystemVoiceAllowed = "native_system_voice_allowed"
        case pythonTTSAllowed = "python_tts_allowed"
        case hardVoiceInvariant = "hard_voice_invariant"
        case status
    }
}

struct NativeUISpecResponse: Decodable {
    let ok: Bool
    let uiSpec: JARVISUISpec

    enum CodingKeys: String, CodingKey {
        case ok
        case uiSpec = "ui_spec"
    }
}

struct JARVISUISpec: Decodable {
    let schema: String
    let receipt: String
    let runtime: String
    let pythonBetaPath: Bool
    let generatedBy: String
    let rendererPolicy: JARVISUIRendererPolicy
    let components: [JARVISUIComponent]
    let actions: [JARVISUIActionDescriptor]
    let queries: [JARVISUIQueryDescriptor]
    let provenance: JARVISUIProvenance

    var actionsByID: [String: JARVISUIActionDescriptor] {
        Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case receipt
        case runtime
        case pythonBetaPath = "python_beta_path"
        case generatedBy = "generated_by"
        case rendererPolicy = "renderer_policy"
        case components
        case actions
        case queries
        case provenance
    }
}

struct JARVISUIRendererPolicy: Decodable {
    let nativeRenderer: Bool
    let trustedHTML: Bool
    let trustedJavaScript: Bool
    let allowedComponents: [JARVISUIComponentKind]
    let blockedComponents: [String]

    enum CodingKeys: String, CodingKey {
        case nativeRenderer = "native_renderer"
        case trustedHTML = "trusted_html"
        case trustedJavaScript = "trusted_javascript"
        case allowedComponents = "allowed_components"
        case blockedComponents = "blocked_components"
    }
}

enum JARVISUIComponentKind: String, Codable, CaseIterable {
    case runtimeStatus
    case metricCards
    case fieldSignalList
    case actionList
}

struct JARVISUIComponent: Decodable, Identifiable {
    let id: String
    let kind: JARVISUIComponentKind
    let title: String
    let subtitle: String?
    let status: String?
    let body: String?
    let fields: [JARVISUIField]
    let metrics: [JARVISUIMetric]
    let signals: [NativeFieldSignal]
    let actionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case subtitle
        case status
        case body
        case fields
        case metrics
        case signals
        case actionIDs = "action_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(JARVISUIComponentKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        fields = try container.decodeIfPresent([JARVISUIField].self, forKey: .fields) ?? []
        metrics = try container.decodeIfPresent([JARVISUIMetric].self, forKey: .metrics) ?? []
        signals = try container.decodeIfPresent([NativeFieldSignal].self, forKey: .signals) ?? []
        actionIDs = try container.decodeIfPresent([String].self, forKey: .actionIDs) ?? []
    }
}

struct JARVISUIField: Decodable, Identifiable {
    var id: String { "\(label):\(value)" }
    let label: String
    let value: String
}

struct JARVISUIMetric: Decodable, Identifiable {
    let id: String
    let label: String
    let value: Double
    let format: String?
}

enum JARVISUIAvailability: String, Decodable {
    case enabled
    case disabled
    case blocked
    case refused
}

enum JARVISRiskClass: String, Decodable {
    case safe = "SAFE"
    case write = "WRITE"
    case sensitive = "SENSITIVE"
    case destructive = "DESTRUCTIVE"
    case prohibited = "PROHIBITED"
}

struct JARVISHASPDescriptor: Decodable {
    let route: String
    let auditEvent: String
    let requiresAuthorization: Bool
    let receiptRequired: Bool
    let adapterStatus: String

    enum CodingKeys: String, CodingKey {
        case route
        case auditEvent = "audit_event"
        case requiresAuthorization = "requires_authorization"
        case receiptRequired = "receipt_required"
        case adapterStatus = "adapter_status"
    }
}

struct JARVISUIActionDescriptor: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String
    let risk: JARVISRiskClass
    let status: JARVISUIAvailability
    let enabled: Bool
    let disabledReason: String?
    let hasp: JARVISHASPDescriptor

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case risk
        case status
        case enabled
        case disabledReason = "disabled_reason"
        case hasp
    }
}

struct JARVISUIQueryDescriptor: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String
    let risk: JARVISRiskClass
    let status: JARVISUIAvailability
    let enabled: Bool
    let hasp: JARVISHASPDescriptor
}

struct JARVISUIProvenance: Decodable {
    let source: String
    let actor: String
    let runtime: String
    let operation: String
    let observedAt: Double
    let pythonBetaPath: Bool
    let evidence: String

    enum CodingKeys: String, CodingKey {
        case source
        case actor
        case runtime
        case operation
        case observedAt = "observed_at"
        case pythonBetaPath = "python_beta_path"
        case evidence
    }
}

enum JARVISNativeUIRegistry {
    static let allowedKinds = Set(JARVISUIComponentKind.allCases)
    static let blockedRendererInputs: Set<String> = ["html", "webView", "script"]

    static func validate(_ spec: JARVISUISpec) throws {
        guard spec.schema == "jarvis.ui.v1" else {
            throw NativeRuntimeError.runtime("Unsupported native UI schema: \(spec.schema)")
        }
        guard spec.runtime == "native-swift-cpp", spec.provenance.runtime == "native-swift-cpp" else {
            throw NativeRuntimeError.runtime("Blocked non-native UI spec runtime: \(spec.runtime)")
        }
        guard spec.pythonBetaPath == false, spec.provenance.pythonBetaPath == false else {
            throw NativeRuntimeError.runtime("Blocked UI spec that reports Python in the beta path.")
        }
        guard spec.rendererPolicy.nativeRenderer else {
            throw NativeRuntimeError.runtime("Blocked UI spec without native renderer policy.")
        }
        guard spec.rendererPolicy.trustedHTML == false, spec.rendererPolicy.trustedJavaScript == false else {
            throw NativeRuntimeError.runtime("Blocked UI spec requesting trusted HTML or JavaScript.")
        }
        guard Set(spec.rendererPolicy.allowedComponents).isSubset(of: allowedKinds) else {
            throw NativeRuntimeError.runtime("Blocked UI spec with unregistered component policy.")
        }
        guard blockedRendererInputs.isSubset(of: Set(spec.rendererPolicy.blockedComponents)) else {
            throw NativeRuntimeError.runtime("Blocked UI spec missing HTML/JS denial receipts.")
        }
        let actionIDs = Set(spec.actions.map(\.id))
        for component in spec.components {
            guard allowedKinds.contains(component.kind) else {
                throw NativeRuntimeError.runtime("Blocked unregistered native component: \(component.kind.rawValue)")
            }
            let missingActions = component.actionIDs.filter { !actionIDs.contains($0) }
            guard missingActions.isEmpty else {
                throw NativeRuntimeError.runtime("Blocked UI action list with unknown actions: \(missingActions.joined(separator: ", "))")
            }
        }
        for action in spec.actions {
            guard action.hasp.route == "native.hasp.dispatch" else {
                throw NativeRuntimeError.runtime("Blocked action without HASP dispatch route: \(action.id)")
            }
            guard !action.hasp.auditEvent.isEmpty, action.hasp.receiptRequired else {
                throw NativeRuntimeError.runtime("Blocked action without audit receipt metadata: \(action.id)")
            }
            if action.status != .enabled {
                guard action.enabled == false, !(action.disabledReason ?? "").isEmpty else {
                    throw NativeRuntimeError.runtime("Blocked action lacks explicit disabled reason: \(action.id)")
                }
            }
        }
        for query in spec.queries {
            guard query.risk == .safe, query.enabled, !query.hasp.auditEvent.isEmpty, query.hasp.receiptRequired else {
                throw NativeRuntimeError.runtime("Blocked unsafe or unaudited UI query: \(query.id)")
            }
        }
    }
}
