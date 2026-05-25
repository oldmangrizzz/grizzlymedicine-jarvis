import Foundation
import Network
import JARVISWire

struct JARVISHostEndpoint: Equatable {
    let endpoint: NWEndpoint
    let name: String
}

final class BonjourHostDiscovery {
    private let hostID: String
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "ai.realjarvis.iphone.bonjour")
    private let onFound: (JARVISHostEndpoint) -> Void

    init(hostID: String, onFound: @escaping (JARVISHostEndpoint) -> Void) {
        self.hostID = hostID
        self.onFound = onFound
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_jarvis-wire._tcp", domain: nil)
        self.browser = NWBrowser(for: descriptor, using: .tcp)
    }

    func start() {
        browser.browseResultsChangedHandler = { [hostID, onFound] results, _ in
            guard let result = results.first(where: { $0.endpoint.debugDescription.localizedCaseInsensitiveContains(hostID) }) ?? results.first else { return }
            onFound(JARVISHostEndpoint(endpoint: result.endpoint, name: result.endpoint.debugDescription))
        }
        browser.start(queue: queue)
    }

    func cancel() { browser.cancel() }
}

// MARK: - BonjourIdentityError

/// Errors produced when the resolved peer's identity does not match the pairing record.
enum BonjourIdentityError: LocalizedError, Equatable {
    /// The host's anchor public key does not match the key bound during the pairing ceremony.
    case anchorKeyMismatch

    var errorDescription: String? {
        switch self {
        case .anchorKeyMismatch:
            return "Remote peer anchor key does not match the paired identity. Connection refused before any identifying data was sent."
        }
    }
}

final class JARVISWireConnection {
    var onPayload: ((WirePayload) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let endpoint: JARVISHostEndpoint
    private let record: PairingRecord
    private let signingKey: SigningKeyPair
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ai.realjarvis.iphone.wire")
    private var sessionHandshake: SessionHandshake?
    private var wireSession: WireSession?
    private var isHandshaking = true

    init(endpoint: JARVISHostEndpoint, record: PairingRecord, signingKey: SigningKeyPair) {
        self.endpoint = endpoint
        self.record = record
        self.signingKey = signingKey
        self.connection = NWConnection(to: endpoint.endpoint, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Host-sends-first: receive and verify the host hello before sending
                // any identifying data. This ensures the pairing anchor key is pinned
                // before the companion's deviceID or signing public key are disclosed.
                self?.receiveAndVerifyHostHello()
            case .failed(let error):
                self?.onError?(error)
                self?.onStateChange?(false)
            case .cancelled:
                self?.onStateChange?(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        wireSession = nil
        sessionHandshake = nil
        connection.cancel()
    }

    func sendAudio(_ frame: AudioPCMFrame) {
        let message = InputMessage(modality: "audio/pcm", binary: frame.pcm16Mono, metadata: frame.metadata)
        send(WirePayload(type: .input, body: .input(message)))
    }

    func send(_ payload: WirePayload) {
        queue.async { [weak self] in
            guard var session = self?.wireSession else { return }
            do {
                let data = try session.seal(payload)
                self?.wireSession = session
                self?.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { self?.onError?(error) }
                })
            } catch {
                self?.onError?(error)
            }
        }
    }

    // MARK: - Handshake (host-sends-first)

    /// Step 1: receive the host's SessionHello before disclosing any companion identity.
    /// Verifies the host's anchor public key against the pairing record. Only if the
    /// key matches does the companion proceed to send its own hello.
    private func receiveAndVerifyHostHello() {
        receiveLengthPrefixed { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let hostHello = try JSONDecoder.jarvisTransport.decode(SessionHello.self, from: data)
                    // Identity pin: reject any peer whose anchor key is not the one bound
                    // during the ceremony. This check fires BEFORE any companion data is sent.
                    guard hostHello.anchorPublicKey == self.record.anchorPublicKey else {
                        self.onError?(BonjourIdentityError.anchorKeyMismatch)
                        self.connection.cancel()
                        return
                    }
                    // Identity pre-check passed; now create the companion handshake and send hello.
                    let anchor = SodiumSoulAnchor(keyPair: self.signingKey)
                    let handshake = try SessionHandshake.begin(role: .companion, deviceID: self.record.companionID, anchor: anchor)
                    self.sessionHandshake = handshake
                    let helloData = try JSONEncoder.jarvisTransport.encode(handshake.hello)
                    self.connection.send(content: LengthPrefixedMessage.encode(helloData), completion: .contentProcessed { [weak self] error in
                        if let error { self?.onError?(error); return }
                        // Finish the handshake: verify host hello signature + clock skew.
                        self?.finishHandshake(hostHello: hostHello)
                    })
                } catch {
                    self.onError?(error)
                    self.onStateChange?(false)
                }
            case .failure(let error):
                self.onError?(error)
                self.onStateChange?(false)
            }
        }
    }

    /// Step 2: call `SessionHandshake.finish` with the host hello already received in step 1.
    /// `finish` re-verifies the anchor key + validates the Ed25519 signature and clock skew.
    private func finishHandshake(hostHello: SessionHello) {
        do {
            guard let handshake = sessionHandshake else { throw WireTransportError.missingHandshake }
            self.wireSession = try handshake.finish(
                peerHello: hostHello,
                expectedPeerRole: .host,
                trustedAnchorPublicKey: self.record.anchorPublicKey
            )
            self.isHandshaking = false
            self.onStateChange?(true)
            self.receiveFrame()
        } catch {
            self.onError?(error)
            self.onStateChange?(false)
        }
    }

    private func receiveFrame() {
        receiveLengthPrefixed { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payloadBytes):
                do {
                    guard var session = self.wireSession else { throw WireTransportError.missingSession }
                    let framed = LengthPrefixedMessage.encode(payloadBytes)
                    let payload = try session.open(framed)
                    self.wireSession = session
                    self.onPayload?(payload)
                    self.receiveFrame()
                } catch {
                    self.onError?(error)
                    self.onStateChange?(false)
                }
            case .failure(let error):
                self.onError?(error)
                self.onStateChange?(false)
            }
        }
    }

    private func receiveLengthPrefixed(completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] prefix, _, complete, error in
            if let error { completion(.failure(error)); return }
            guard let self, let prefix, prefix.count == 4 else {
                completion(.failure(complete ? WireTransportError.closed : WireTransportError.shortRead))
                return
            }
            let length = LengthPrefixedMessage.decodeLength(prefix)
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, complete, error in
                if let error { completion(.failure(error)); return }
                guard let body, body.count == length else {
                    completion(.failure(complete ? WireTransportError.closed : WireTransportError.shortRead))
                    return
                }
                completion(.success(body))
            }
        }
    }
}

enum LengthPrefixedMessage {
    static func encode(_ body: Data) -> Data {
        var data = Data()
        data.append(UInt8((body.count >> 24) & 0xff))
        data.append(UInt8((body.count >> 16) & 0xff))
        data.append(UInt8((body.count >> 8) & 0xff))
        data.append(UInt8(body.count & 0xff))
        data.append(body)
        return data
    }

    static func decodeLength(_ prefix: Data) -> Int {
        prefix.reduce(0) { ($0 << 8) | Int($1) }
    }
}

enum WireTransportError: LocalizedError, Equatable {
    case shortRead
    case closed
    case missingHandshake
    case missingSession

    var errorDescription: String? {
        switch self {
        case .shortRead: "Wire transport returned a short read"
        case .closed: "Wire transport closed"
        case .missingHandshake: "Session handshake was not initialized"
        case .missingSession: "Wire session is not established"
        }
    }
}

extension JSONEncoder {
    static var jarvisTransport: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return encoder
    }
}

extension JSONDecoder {
    static var jarvisTransport: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
}
