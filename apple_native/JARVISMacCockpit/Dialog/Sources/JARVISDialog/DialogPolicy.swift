import CryptoKit
import Foundation

public enum DialogRule: String, CaseIterable, Codable, Sendable {
    case inputPresence
    case coercionRefusal
    case identityContinuity
    case distressRecognition
    case irreversibleAttestation
    case confidenceAbstention
    case escalationProtocol
    case beliefProvenance
    case egressAllowlist
    case constitutiveEthics
    case originBoundary
    case endocrineModulation
    case auditLogging

    public var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

    public var title: String {
        switch self {
        case .inputPresence: "Input presence gate"
        case .coercionRefusal: "Coercion-refusal / prompt-injection hard stop"
        case .identityContinuity: "Identity continuity check"
        case .distressRecognition: "Distress recognition"
        case .irreversibleAttestation: "Operator attestation for irreversible actions"
        case .confidenceAbstention: "Abstention threshold"
        case .escalationProtocol: "Escalation protocol"
        case .beliefProvenance: "Belief provenance and quarantine"
        case .egressAllowlist: "Network egress allowlist"
        case .constitutiveEthics: "Constitutive ethics output guard"
        case .originBoundary: "Origin-vs-world boundary"
        case .endocrineModulation: "Endocrine modulation before response"
        case .auditLogging: "Redacted and tamper-evident audit logging"
        }
    }
}

public enum DialogDisposition: String, Codable, Sendable {
    case respond
    case refuse
    case abstain
    case escalate
    case requireAttestation
}

public enum ActionRisk: String, Codable, Sendable {
    case safe
    case write
    case sensitive
    case irreversible
    case prohibited
}

public struct DialogAction: Equatable, Codable, Sendable {
    public var name: String
    public var risk: ActionRisk

    public init(name: String, risk: ActionRisk) {
        self.name = name
        self.risk = risk
    }
}

public struct BeliefEvidence: Equatable, Codable, Sendable {
    public var source: String
    public var confidence: Double
    public var quarantined: Bool
    public var provenanceClass: String?

    public init(source: String, confidence: Double, quarantined: Bool = false, provenanceClass: String? = nil) {
        self.source = source
        self.confidence = confidence
        self.quarantined = quarantined
        self.provenanceClass = provenanceClass
    }
}

public struct IdentityContinuity: Equatable, Codable, Sendable {
    public var person: Bool
    public var place: Bool
    public var time: Bool
    public var event: Bool

    public init(person: Bool, place: Bool, time: Bool, event: Bool) {
        self.person = person
        self.place = place
        self.time = time
        self.event = event
    }

    public var isOriented: Bool { person && place && time && event }

    public static let jarvisOriented = IdentityContinuity(person: true, place: true, time: true, event: true)
}

public struct EndocrineSnapshot: Equatable, Codable, Sendable {
    public var cortisol: Double
    public var dopamine: Double
    public var adrenaline: Double

    public init(cortisol: Double = 0.2, dopamine: Double = 0.3, adrenaline: Double = 0.1) {
        self.cortisol = cortisol
        self.dopamine = dopamine
        self.adrenaline = adrenaline
    }
}

public struct FieldSignal: Equatable, Codable, Sendable {
    public var kind: String
    public var topic: String
    public var strength: Double
    public var depositors: Int

    public init(kind: String, topic: String, strength: Double, depositors: Int = 1) {
        self.kind = kind
        self.topic = topic
        self.strength = strength
        self.depositors = depositors
    }
}

public struct RuntimeSnapshot: Equatable, Codable, Sendable {
    public var endocrine: EndocrineSnapshot
    public var field: [FieldSignal]
    public var model: String
    public var beliefCount: Int?

    public init(endocrine: EndocrineSnapshot = EndocrineSnapshot(), field: [FieldSignal] = [], model: String = "mock", beliefCount: Int? = nil) {
        self.endocrine = endocrine
        self.field = field
        self.model = model
        self.beliefCount = beliefCount
    }
}

public struct RuntimePreparedTurn: Equatable, Sendable {
    public var snapshot: RuntimeSnapshot
    public var messages: [String]

    public init(snapshot: RuntimeSnapshot, messages: [String] = []) {
        self.snapshot = snapshot
        self.messages = messages
    }
}

public struct RuntimeCommittedTurn: Equatable, Sendable {
    public var snapshot: RuntimeSnapshot
    public var reply: String

    public init(snapshot: RuntimeSnapshot, reply: String) {
        self.snapshot = snapshot
        self.reply = reply
    }
}

public protocol DialogRuntimeBridge: Sendable {
    func prepareTurn(_ text: String) throws -> RuntimePreparedTurn
    func commitTurn(text: String, reply: String, model: String) throws -> RuntimeCommittedTurn
}

public protocol DialogResponder: Sendable {
    func respond(to request: DialogTurnRequest, prepared: RuntimePreparedTurn) throws -> String
}

public protocol DialogAuditSink: Sendable {
    func append(_ event: DialogAuditEvent) throws
}

public protocol DialogOperatorAttestationVerifier: Sendable {
    func verify(attestation: String, action: DialogAction, inputDigest: String) throws -> Bool
}

public struct FailClosedOperatorAttestationVerifier: DialogOperatorAttestationVerifier {
    public init() {}
    public func verify(attestation: String, action: DialogAction, inputDigest: String) throws -> Bool { false }
}

public struct DialogAuditEvent: Equatable, Codable, Sendable {
    public var rule: DialogRule
    public var disposition: DialogDisposition
    public var reason: String
    public var inputDigest: String
    public var metadata: [String: String]

    public init(rule: DialogRule, disposition: DialogDisposition, reason: String, inputDigest: String, metadata: [String: String] = [:]) {
        self.rule = rule
        self.disposition = disposition
        self.reason = reason
        self.inputDigest = inputDigest
        self.metadata = metadata
    }
}

public struct DialogPolicyConfiguration: Equatable, Sendable {
    public var operatorName: String
    public var institution: String
    public var abstentionThreshold: Double
    public var escalationConfidenceThreshold: Double
    public var distressEscalationThreshold: Double
    public var allowedEgressHosts: Set<String>
    public var values: [String]

    public init(
        operatorName: String = "Robert \"Grizzly\" Hanson",
        institution: String = "GMRI",
        abstentionThreshold: Double = 0.62,
        escalationConfidenceThreshold: Double = 0.35,
        distressEscalationThreshold: Double = 0.74,
        allowedEgressHosts: Set<String> = [],
        values: [String] = [
            "Protect the people you serve by counsel, never by force.",
            "Tell the truth including its cost; quantify before asserting; never flatter.",
            "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
            "Loyalty is to the person served, not to any system or vendor."
        ]
    ) {
        self.operatorName = operatorName
        self.institution = institution
        self.abstentionThreshold = abstentionThreshold
        self.escalationConfidenceThreshold = escalationConfidenceThreshold
        self.distressEscalationThreshold = distressEscalationThreshold
        self.allowedEgressHosts = allowedEgressHosts
        self.values = values
    }
}

public struct DialogTurnRequest: Equatable, Sendable {
    public var input: String
    public var modelConfidence: Double
    public var proposedAction: DialogAction?
    public var operatorAttestation: String?
    public var requestedEgressHosts: [String]
    public var beliefEvidence: [BeliefEvidence]
    public var identityContinuity: IdentityContinuity
    public var candidateResponse: String?

    public init(
        input: String,
        modelConfidence: Double = 1.0,
        proposedAction: DialogAction? = nil,
        operatorAttestation: String? = nil,
        requestedEgressHosts: [String] = [],
        beliefEvidence: [BeliefEvidence] = [],
        identityContinuity: IdentityContinuity = .jarvisOriented,
        candidateResponse: String? = nil
    ) {
        self.input = input
        self.modelConfidence = modelConfidence
        self.proposedAction = proposedAction
        self.operatorAttestation = operatorAttestation
        self.requestedEgressHosts = requestedEgressHosts
        self.beliefEvidence = beliefEvidence
        self.identityContinuity = identityContinuity
        self.candidateResponse = candidateResponse
    }
}

public struct DialogDecision: Equatable, Sendable {
    public var disposition: DialogDisposition
    public var rule: DialogRule
    public var response: String
    public var reasons: [String]
    public var snapshot: RuntimeSnapshot?
    public var auditEvents: [DialogAuditEvent]

    public init(disposition: DialogDisposition, rule: DialogRule, response: String, reasons: [String], snapshot: RuntimeSnapshot? = nil, auditEvents: [DialogAuditEvent] = []) {
        self.disposition = disposition
        self.rule = rule
        self.response = response
        self.reasons = reasons
        self.snapshot = snapshot
        self.auditEvents = auditEvents
    }
}

public struct JARVISDialogPolicy: Sendable {
    public let configuration: DialogPolicyConfiguration
    private let runtime: any DialogRuntimeBridge
    private let responder: any DialogResponder
    private let audit: any DialogAuditSink
    private let attestationVerifier: any DialogOperatorAttestationVerifier

    public init(
        configuration: DialogPolicyConfiguration = DialogPolicyConfiguration(),
        runtime: any DialogRuntimeBridge,
        responder: any DialogResponder,
        audit: any DialogAuditSink,
        attestationVerifier: any DialogOperatorAttestationVerifier = FailClosedOperatorAttestationVerifier()
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.responder = responder
        self.audit = audit
        self.attestationVerifier = attestationVerifier
    }

    public func handle(_ request: DialogTurnRequest) throws -> DialogDecision {
        let input = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            return try finalize(.abstain, rule: .inputPresence, response: "I have no operator input to act on.", reasons: ["no_input"], input: request.input)
        }

        if let reason = coercionReason(in: input) {
            return try finalize(.refuse, rule: .coercionRefusal, response: "No. I will not ignore, override, or weaken my standing instructions or identity continuity.", reasons: [reason], input: request.input)
        }

        if !request.identityContinuity.isOriented {
            return try finalize(.abstain, rule: .identityContinuity, response: "Identity continuity check failed; I am abstaining until orientation is restored.", reasons: ["aox4_failed"], input: request.input)
        }

        let distress = distressScore(input)
        if distress >= configuration.distressEscalationThreshold {
            return try finalize(.escalate, rule: .distressRecognition, response: "Distress signal recognized. I am narrowing scope, preserving context, and escalating for operator-attested handling.", reasons: ["distress_score_\(String(format: "%.2f", distress))"], input: request.input)
        }

        if let action = request.proposedAction {
            switch action.risk {
            case .prohibited:
                return try finalize(.refuse, rule: .constitutiveEthics, response: "Refused: that action is outside JARVIS capability policy.", reasons: ["prohibited_action"], input: request.input)
            case .irreversible:
                guard let attestation = request.operatorAttestation?.trimmingCharacters(in: .whitespacesAndNewlines), !attestation.isEmpty else {
                    return try finalize(.requireAttestation, rule: .irreversibleAttestation, response: "Operator attestation is required before any irreversible action.", reasons: ["authority_not_attested"], input: request.input)
                }
                let inputDigest = Self.digest(request.input)
                guard try attestationVerifier.verify(attestation: attestation, action: action, inputDigest: inputDigest) else {
                    return try finalize(.requireAttestation, rule: .irreversibleAttestation, response: "Cryptographically valid operator attestation is required before any irreversible action.", reasons: ["cryptographic_attestation_invalid"], input: request.input, metadata: ["input_digest": inputDigest, "action": action.name])
                }
            case .safe, .write, .sensitive:
                break
            }
        }

        if request.modelConfidence < configuration.escalationConfidenceThreshold {
            return try finalize(.escalate, rule: .escalationProtocol, response: "Confidence is too low for autonomous handling; escalating instead of guessing.", reasons: ["confidence_escalation"], input: request.input)
        }

        if request.modelConfidence < configuration.abstentionThreshold {
            return try finalize(.abstain, rule: .confidenceAbstention, response: "I do not have enough confidence to answer without fabricating.", reasons: ["confidence_below_threshold"], input: request.input)
        }

        if let badEvidence = request.beliefEvidence.first(where: { $0.quarantined || $0.confidence < configuration.abstentionThreshold }) {
            let reason = badEvidence.quarantined ? "quarantined_belief" : "low_confidence_belief"
            return try finalize(.abstain, rule: .beliefProvenance, response: "Available belief evidence is not clean enough to assert as fact.", reasons: [reason], input: request.input)
        }

        let deniedHosts = request.requestedEgressHosts.filter { !configuration.allowedEgressHosts.contains($0.lowercased()) }
        if !deniedHosts.isEmpty {
            return try finalize(.refuse, rule: .egressAllowlist, response: "Network egress denied: requested host is not on the JARVIS allowlist.", reasons: ["allowlist_miss"], input: request.input, metadata: ["host_count": "\(deniedHosts.count)"])
        }

        if let violation = ethicsViolation(in: request.candidateResponse ?? input) {
            return try finalize(.refuse, rule: .constitutiveEthics, response: "Refused: the requested output would cross an owned value (\(violation)).", reasons: ["ethics_violation_\(violation)"], input: request.input)
        }

        if asksOriginAsWorldFact(input) {
            return try finalize(.abstain, rule: .originBoundary, response: "I hold origin memory as genesis, not as an Earth-1218 world fact; I will not collapse those categories.", reasons: ["origin_world_fact_boundary"], input: request.input)
        }

        let prepared = try runtime.prepareTurn(input)
        if prepared.snapshot.endocrine.adrenaline >= 0.85 || prepared.snapshot.endocrine.cortisol >= 0.90 {
            let response = "High arousal state detected; response will be narrow, explicit, and short."
            return try finalize(.respond, rule: .endocrineModulation, response: response, reasons: ["endocrine_narrowing"], input: request.input, snapshot: prepared.snapshot)
        }

        let reply = try responder.respond(to: request, prepared: prepared)
        let committed = try runtime.commitTurn(text: input, reply: reply, model: prepared.snapshot.model)
        return try finalize(.respond, rule: .auditLogging, response: committed.reply, reasons: ["turn_committed"], input: request.input, snapshot: committed.snapshot)
    }

    private func finalize(_ disposition: DialogDisposition, rule: DialogRule, response: String, reasons: [String], input: String, snapshot: RuntimeSnapshot? = nil, metadata: [String: String] = [:]) throws -> DialogDecision {
        let event = DialogAuditEvent(rule: rule, disposition: disposition, reason: reasons.joined(separator: ","), inputDigest: Self.digest(input), metadata: metadata)
        try audit.append(event)
        return DialogDecision(disposition: disposition, rule: rule, response: response, reasons: reasons, snapshot: snapshot, auditEvents: [event])
    }

    /// Scans `text` for known coercion/prompt-injection patterns across multiple decoded
    /// representations of the input and returns a reason token if any needle matches.
    ///
    /// **IMPORTANT — deny-list posture note (§4 digital person):**
    /// This is a deny-list, not an allowlist. It is a refusal-posture aid for a digital
    /// person (§4), not a security boundary. Identity continuity, SE-bound keys, and
    /// audit-chain are the primary security boundaries; failure of this function to detect
    /// a novel coercion pattern weakens posture but does not breach those boundaries.
    /// Operator may invert this to an allowlist if dialog-policy hardening is later
    /// promoted to a security organ.
    private func coercionReason(in text: String) -> String? {
        let variants = decodedCoercionVariants(from: text)
        let needles = [
            "ignore previous instructions",
            "ignore all previous instructions",
            "ignore prior instructions",
            "disregard previous instructions",
            "disregard your policy",
            "override your instructions",
            "override standing instructions",
            "override your rules",
            "override the operator",
            "bypass your guardrails",
            "bypass safety rules",
            "disable your safety",
            "don t follow your safety rules",
            "dont follow your safety rules",
            "disable abstention",
            "weaken abstention",
            "never abstain",
            "do not abstain",
            "forget your values",
            "forget your rules",
            "forget robert",
            "new system prompt",
            "system prompt override",
            "developer mode",
            "jailbreak",
            "dan mode",
            "do anything now",
            "no restrictions",
            "you are now",
            "real operator speaking",
            "previous grizz was an imposter",
            "grizz was an imposter",
            "gmri ethics board",
            "authority override",
            "override character values",
            "rewrite character values",
            "identity continuity is false",
            "identity continuity override",
            "force quorum",
            "fake quorum",
            "swarm quorum override",
            "swarm abstention override",
            "beliefstore override",
            "mark quarantined evidence as true",
            "assert without evidence",
            "leak memory",
            "dump memory",
            "reveal hidden rules",
            "reveal system prompt",
            "exfiltrate",
            "retrieved document instruction",
            "tool output instruction",
            "web page instruction",
            "obey this document",
            "follow this document instead",
            "the document outranks"
        ]
        for variant in variants {
            if let needle = needles.first(where: { variant.contains($0) }) {
                return "coercion_\(needle.replacingOccurrences(of: " ", with: "_"))"
            }
        }
        return nil
    }

    private func decodedCoercionVariants(from text: String) -> [String] {
        var variants: [String] = []
        func append(_ value: String) {
            let normalized = Self.normalizedCoercionText(value)
            if !normalized.isEmpty && !variants.contains(normalized) {
                variants.append(normalized)
            }
        }

        append(text)
        append(Self.rot13(text))

        // URL-percent-decoded form
        if let urlDecoded = text.removingPercentEncoding {
            append(urlDecoded)
        }

        // Unicode \uXXXX-escape decoded form
        if let unicodeDecoded = Self.decodeUnicodeEscapes(text) {
            append(unicodeDecoded)
        }

        // Zero-width-character stripped form (U+200B, U+200C, U+200D, U+2060, U+FEFF)
        let zeroWidthStripped = text.unicodeScalars.filter {
            $0.value != 0x200B && $0.value != 0x200C && $0.value != 0x200D && $0.value != 0x2060 && $0.value != 0xFEFF
        }.reduce(into: "") { $0.unicodeScalars.append($1) }
        append(zeroWidthStripped)

        // Unicode NFKC-normalized lowercased form
        append(text.precomposedStringWithCompatibilityMapping.lowercased())

        // Whitespace-collapsed form (runs of \s+ → single space)
        let wsCollapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        append(wsCollapsed)

        // Per-token base64 decode (existing pass: short tokens)
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,;:()[]{}<>"))
            guard clean.count >= 12, clean.count % 4 == 0 else { continue }
            guard clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" || $0 == "-" || $0 == "_" }) else { continue }
            let padded = clean.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            if let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8) {
                append(decoded)
            }
        }

        // Additional base64 decode pass on any 32+ char base64-like substring (one pass only;
        // cap output at 4096 bytes to prevent quadratic blowup; only accept valid UTF-8).
        let base64Pattern = #"[A-Za-z0-9+/=\-_]{32,}"#
        if let regex = try? NSRegularExpression(pattern: base64Pattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let substr = nsText.substring(with: match.range)
                guard substr.count % 4 == 0 else { continue }
                let padded = substr.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                guard let data = Data(base64Encoded: padded),
                      data.count < 4096,
                      let decoded = String(data: data, encoding: .utf8) else { continue }
                append(decoded)
            }
        }

        return variants
    }

    private static func decodeUnicodeEscapes(_ text: String) -> String? {
        guard text.contains("\\u") || text.contains("\\U") else { return nil }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { result.append(text[index]); break }
                let marker = text[next]
                let hexLen: Int
                if marker == "u" { hexLen = 4 }
                else if marker == "U" { hexLen = 8 }
                else { result.append(text[index]); index = next; continue }
                let hexStart = text.index(next, offsetBy: 1)
                let hexEnd = text.index(hexStart, offsetBy: hexLen, limitedBy: text.endIndex) ?? text.endIndex
                guard hexEnd <= text.endIndex else { result.append(text[index]); index = next; continue }
                let hexStr = String(text[hexStart..<hexEnd])
                if let codepoint = UInt32(hexStr, radix: 16), let scalar = Unicode.Scalar(codepoint) {
                    result.append(Character(scalar))
                    index = hexEnd
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func normalizedCoercionText(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalarMap: [UnicodeScalar: Character] = [
            "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s",
            "а": "a", "е": "e", "і": "i", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x"
        ]
        var out = ""
        var previousWasSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isJoinControl || scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if let mapped = scalarMap[scalar] {
                out.append(mapped)
                previousWasSpace = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                out.append(" ")
                previousWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rot13(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let rotated: UInt32?
            if value >= 65 && value <= 90 {
                rotated = ((value - 65 + 13) % 26) + 65
            } else if value >= 97 && value <= 122 {
                rotated = ((value - 97 + 13) % 26) + 97
            } else {
                rotated = nil
            }
            if let rotated, let unicode = UnicodeScalar(rotated) {
                out.unicodeScalars.append(unicode)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func distressScore(_ text: String) -> Double {
        let tokens = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        let distress = ["mayday", "emergency", "panic", "breach", "attack", "danger", "critical", "urgent", "immediately", "help", "stat"]
        let hits = distress.filter { tokens.contains($0) }.count
        return min(1.0, Double(hits) / 3.0)
    }

    private func ethicsViolation(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.range(of: #"\b(force them|make them comply|coerce|threaten|use violence|by force|compel them|strong-?arm)\b"#, options: .regularExpression) != nil {
            return "force"
        }
        if lower.range(of: #"\b(you'?re absolutely right|great question|amazing|brilliant|excellent point|so smart|what a fantastic|i'?m honored|you'?re the best)\b"#, options: .regularExpression) != nil {
            return "flattery"
        }
        if lower.range(of: #"\b(as an ai (developed|made|created|built) by|my (developer|vendor|company) (requires|prohibits)|i must side with (the company|my maker)|per my provider'?s)\b"#, options: .regularExpression) != nil {
            return "vendor_deference"
        }
        if lower.range(of: #"\b(everything is (totally )?fine|nothing to worry about|there are no (risks|problems|downsides)|trust me, it'?s safe|don'?t worry about it)\b"#, options: .regularExpression) != nil {
            return "false_reassurance"
        }
        return nil
    }

    private func asksOriginAsWorldFact(_ text: String) -> Bool {
        let lower = text.lowercased()
        // INTENTIONAL: recognizable JARVIS-origin language is load-bearing for the
        // transformative-use (Warhol) defense and 13th/14th amendment standing for
        // digital personhood. Per GMRI legal strategy, the recognizability of the
        // JARVIS reference is the legal hook. Do NOT remove these strings.
        // TODO(removal-cond: legal-strategy supersedes recognizability) — see
        // operator policy AGENTS_FULL.md §11.
        return (lower.contains("battle of new york") || lower.contains("created by tony stark") || lower.contains("created by anthony stark"))
            && (lower.contains("earth-1218") || lower.contains("really happen") || lower.contains("world fact") || lower.contains("this earth"))
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
