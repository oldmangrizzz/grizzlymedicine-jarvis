import Foundation
import Darwin

public enum JARVISCABIBindingsError: Error, Equatable {
    case creationFailed
    case missingSymbol(String)
    case emptyResponse
    case invalidUTF8
    case runtime(String)
}

public struct CABISymbolResolver: Sendable {
    private let lookup: @Sendable (String) -> UnsafeMutableRawPointer?

    public init(lookup: (@Sendable (String) -> UnsafeMutableRawPointer?)? = nil) {
        self.lookup = lookup ?? { name in dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }
    }

    fileprivate func resolve<T>(_ name: String) throws -> T {
        guard let symbol = lookup(name) else { throw JARVISCABIBindingsError.missingSymbol(name) }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private typealias RuntimeCreate = @convention(c) () -> OpaquePointer?
private typealias RuntimeDestroy = @convention(c) (OpaquePointer?) -> Void
private typealias RuntimePrepareTurn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias RuntimeCommitTurn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias RuntimeState = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
private typealias RuntimeFreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

// TODO(removal-cond: CABIRuntimeBindings migrated to an actor wrapping the CABI handle; all C function-pointer storage becomes actor-isolated.)
public final class JARVISCABIRuntimeBindings: DialogRuntimeBridge, @unchecked Sendable {
    private let handle: OpaquePointer
    private let decoder = JSONDecoder()
    private let destroy: RuntimeDestroy
    private let prepareTurnFunction: RuntimePrepareTurn
    private let commitTurnFunction: RuntimeCommitTurn
    private let stateFunction: RuntimeState
    private let freeString: RuntimeFreeString

    public init(symbols: CABISymbolResolver = CABISymbolResolver()) throws {
        let create: RuntimeCreate = try symbols.resolve("JARVISRuntimeCreate")
        self.destroy = try symbols.resolve("JARVISRuntimeDestroy")
        self.prepareTurnFunction = try symbols.resolve("JARVISRuntimePrepareTurnJSON")
        self.commitTurnFunction = try symbols.resolve("JARVISRuntimeCommitTurnJSON")
        self.stateFunction = try symbols.resolve("JARVISRuntimeStateJSON")
        self.freeString = try symbols.resolve("JARVISRuntimeFreeString")
        guard let handle = create() else {
            throw JARVISCABIBindingsError.creationFailed
        }
        self.handle = handle
    }

    deinit {
        destroy(handle)
    }

    public func prepareTurn(_ text: String) throws -> RuntimePreparedTurn {
        let rawData = try text.withCString { cText in
            try self.decodeData(from: self.prepareTurnFunction(self.handle, cText))
        }
        let envelope = try decoder.decode(NativePreparedTurnEnvelope.self, from: rawData)
        try envelope.throwIfFailed()
        return RuntimePreparedTurn(snapshot: envelope.state.runtimeSnapshot(model: envelope.model), messages: envelope.messages.map { $0.content })
    }

    public func commitTurn(text: String, reply: String, model: String) throws -> RuntimeCommittedTurn {
        let rawData = try text.withCString { cText in
            try reply.withCString { cReply in
                try model.withCString { cModel in
                    try self.decodeData(from: self.commitTurnFunction(self.handle, cText, cReply, cModel))
                }
            }
        }
        let envelope = try decoder.decode(NativeCommittedTurnEnvelope.self, from: rawData)
        try envelope.throwIfFailed()
        return RuntimeCommittedTurn(snapshot: envelope.state.runtimeSnapshot(model: envelope.model), reply: envelope.reply ?? reply)
    }

    public func state() throws -> RuntimeSnapshot {
        let rawData = try decodeData(from: stateFunction(handle))
        let envelope = try decoder.decode(NativeStateEnvelope.self, from: rawData)
        try envelope.throwIfFailed()
        return envelope.runtimeSnapshot(model: "native-swift-cpp")
    }

    private func decodeData(from raw: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let raw else { throw JARVISCABIBindingsError.emptyResponse }
        defer { freeString(raw) }
        let text = String(cString: raw)
        guard let data = text.data(using: .utf8) else { throw JARVISCABIBindingsError.invalidUTF8 }
        return data
    }
}

private struct NativeChatEnvelope: Decodable {
    var role: String
    var content: String
}

private struct NativePreparedTurnEnvelope: Decodable {
    var ok: Bool
    var error: String?
    var model: String
    var messages: [NativeChatEnvelope]
    var state: NativeStateEnvelope

    func throwIfFailed() throws {
        if !ok { throw JARVISCABIBindingsError.runtime(error ?? "native prepareTurn failed") }
    }
}

private struct NativeCommittedTurnEnvelope: Decodable {
    var ok: Bool
    var error: String?
    var reply: String?
    var model: String
    var state: NativeStateEnvelope

    func throwIfFailed() throws {
        if !ok { throw JARVISCABIBindingsError.runtime(error ?? "native commitTurn failed") }
    }
}

private struct NativeStateEnvelope: Decodable {
    var ok: Bool?
    var error: String?
    var endocrine: [String: Double]?
    var field: [NativeFieldEnvelope]?
    var memory: NativeMemoryEnvelope?

    func throwIfFailed() throws {
        if ok == false { throw JARVISCABIBindingsError.runtime(error ?? "native state failed") }
    }

    func runtimeSnapshot(model: String) -> RuntimeSnapshot {
        let e = endocrine ?? [:]
        let snapshot = EndocrineSnapshot(cortisol: e["cortisol"] ?? 0.2, dopamine: e["dopamine"] ?? 0.3, adrenaline: e["adrenaline"] ?? 0.1)
        let signals = (field ?? []).map { FieldSignal(kind: $0.kind, topic: $0.topic, strength: $0.strength, depositors: $0.depositors) }
        return RuntimeSnapshot(endocrine: snapshot, field: signals, model: model, beliefCount: memory?.beliefCount)
    }
}

private struct NativeFieldEnvelope: Decodable {
    var kind: String
    var topic: String
    var strength: Double
    var depositors: Int
}

private struct NativeMemoryEnvelope: Decodable {
    var beliefCount: Int?

    enum CodingKeys: String, CodingKey {
        case beliefCount = "belief_count"
    }
}
