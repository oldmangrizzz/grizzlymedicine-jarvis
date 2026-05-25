import Foundation

public struct PairingAdmissionController: Sendable {
    public let maximumPairingRequestsPerSource: Int
    public let maximumSessionInitRequestsPerSource: Int
    private var pairingRequestsBySource: [String: Int] = [:]
    private var sessionInitRequestsBySource: [String: Int] = [:]
    private var consumedOfferNonces: Set<Data> = []
    private var consumedResponseNonces: Set<Data> = []

    public init(maximumPairingRequestsPerSource: Int = 16, maximumSessionInitRequestsPerSource: Int = 32) {
        self.maximumPairingRequestsPerSource = maximumPairingRequestsPerSource
        self.maximumSessionInitRequestsPerSource = maximumSessionInitRequestsPerSource
    }

    public mutating func recordPairingRequest(from sourceID: String) throws {
        let count = (pairingRequestsBySource[sourceID] ?? 0) + 1
        pairingRequestsBySource[sourceID] = count
        if count > maximumPairingRequestsPerSource { throw WireError.resourceLimitExceeded }
    }

    public mutating func recordSessionInit(from sourceID: String) throws {
        let count = (sessionInitRequestsBySource[sourceID] ?? 0) + 1
        sessionInitRequestsBySource[sourceID] = count
        if count > maximumSessionInitRequestsPerSource { throw WireError.resourceLimitExceeded }
    }

    public mutating func completeEnrollment(offer: PairingOffer, response: PairingResponse, operatorAttestation: OperatorAttestation, anchor: SoulAnchorSigning, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> PairingRecord {
        if consumedOfferNonces.contains(offer.offerNonce) || consumedResponseNonces.contains(response.responseNonce) {
            throw WireError.replayDetected
        }
        let record = try PairingCeremony.completeEnrollment(offer: offer, response: response, operatorAttestation: operatorAttestation, anchor: anchor, nowUnixMs: nowUnixMs)
        consumedOfferNonces.insert(offer.offerNonce)
        consumedResponseNonces.insert(response.responseNonce)
        return record
    }
}
