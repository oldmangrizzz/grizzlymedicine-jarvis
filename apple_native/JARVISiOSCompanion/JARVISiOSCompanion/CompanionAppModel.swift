import Foundation
import SwiftUI
import JARVISWire

@MainActor
enum CompanionConnectionState: Equatable {
    case unpaired
    case discovering
    case connecting
    case connected
    case disconnected
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var pairingRecord: PairingRecord?
    @Published private(set) var connectionState: CompanionConnectionState = .unpaired
    @Published private(set) var isTransmittingAudio = false
    @Published var incomingPairingPayload = ""
    @Published var lastError: String?

    private let pairingStore: PairingStore
    private let notificationRelay: DistressNotificationRelaying
    private lazy var audioCapture = AudioCaptureEngine()
    private lazy var audioPlayback = AudioPlaybackEngine()
    private var discovery: BonjourHostDiscovery?
    private var connection: JARVISWireConnection?
    private var signingKey: SigningKeyPair?

    init(pairingStore: PairingStore = KeychainPairingStore(), notificationRelay: DistressNotificationRelaying = LocalDistressNotificationRelay()) {
        self.pairingStore = pairingStore
        self.notificationRelay = notificationRelay
        do {
            let bundle = Bundle.main
            try SiriQuarantineGuard.assertQuarantined(bundle: bundle)
            if let material = try pairingStore.load() {
                pairingRecord = material.record
                signingKey = material.companionSigningKey
                connectionState = .disconnected
                reconnect()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func acceptPairingURL(_ url: URL) {
        guard url.scheme == "jarvis-wire" else { return }
        // Parse and validate the payload before storing. Rejects malformed, oversized,
        // or excessively-nested JSON before any pairing attempt is made.
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let offerEncoded = queryItems.first(where: { $0.name == "offer" })?.value,
              let offerData = Data(base64URLEncoded: offerEncoded) else {
            lastError = "Invalid pairing URL: missing or malformed offer parameter."
            return
        }
        do {
            let offer = try decodeBoundedJSON(offerData, as: PairingOffer.self, maxBytes: 4096, maxDepth: 4)
            guard !offer.hostID.isEmpty, !offer.anchorPublicKey.isEmpty else {
                lastError = "Invalid pairing URL: required fields missing."
                return
            }
            incomingPairingPayload = url.absoluteString
        } catch {
            lastError = "Invalid pairing URL: \(error.localizedDescription)"
        }
    }

    func completePairing(qrPayload: String, displayedShortCode: String) {
        do {
            let coordinator = PairingCoordinator()
            let material = try coordinator.completePairing(qrPayload: qrPayload, displayedShortCode: displayedShortCode)
            try pairingStore.save(material)
            pairingRecord = material.record
            signingKey = material.companionSigningKey
            lastError = nil
            reconnect()
        } catch {
            lastError = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func reconnect() {
        guard let record = pairingRecord, let signingKey else {
            connectionState = .unpaired
            return
        }
        connectionState = .discovering
        discovery = BonjourHostDiscovery(hostID: record.hostID) { [weak self] endpoint in
            Task { @MainActor in self?.connect(to: endpoint, record: record, signingKey: signingKey) }
        }
        discovery?.start()
    }

    func connect(to endpoint: JARVISHostEndpoint, record: PairingRecord, signingKey: SigningKeyPair) {
        connectionState = .connecting
        let connection = JARVISWireConnection(endpoint: endpoint, record: record, signingKey: signingKey)
        connection.onPayload = { [weak self] payload in
            Task { @MainActor in self?.handle(payload: payload) }
        }
        connection.onStateChange = { [weak self] connected in
            Task { @MainActor in self?.connectionState = connected ? .connected : .disconnected }
        }
        connection.onError = { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
        self.connection = connection
        connection.start()
    }

    func togglePushToTalk() {
        isTransmittingAudio ? stopPushToTalk() : startPushToTalk()
    }

    func startPushToTalk() {
        guard connectionState.isConnected else { return }
        do {
            try audioCapture.start { [weak self] frame in
                Task { @MainActor in self?.connection?.sendAudio(frame) }
            }
            isTransmittingAudio = true
        } catch {
            lastError = "Microphone start failed: \(error.localizedDescription)"
        }
    }

    func stopPushToTalk() {
        audioCapture.stop()
        isTransmittingAudio = false
    }

    func handle(payload: WirePayload) {
        switch payload.body {
        case .output(let output):
            if output.surface == "iphone-speaker", let pcm = output.binary {
                audioPlayback.play(pcm16Mono: pcm, sampleRate: Double(output.metadata["sampleRate"] ?? "16000") ?? 16_000)
            }
        case .distress:
            notificationRelay.relayDistressBanner()
        default:
            break
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundGracefully()
        case .active:
            if pairingRecord != nil, connectionState == .disconnected { reconnect() }
        default:
            break
        }
    }

    func backgroundGracefully() {
        stopPushToTalk()
        connection?.disconnect()
        connection = nil
        discovery?.cancel()
        discovery = nil
        connectionState = pairingRecord == nil ? .unpaired : .disconnected
    }

    func forgetPairing() {
        backgroundGracefully()
        do { try pairingStore.delete() } catch { lastError = error.localizedDescription }
        pairingRecord = nil
        signingKey = nil
        connectionState = .unpaired
    }
}
