import Foundation

public struct ReplayProtector: Sendable {
    public let maximumClockSkewMs: Int64
    private var seenNonces: Set<Data> = []
    private var highestSequence: UInt64 = 0
    private var hasSequence = false

    public init(maximumClockSkewMs: Int64 = 300_000) {
        self.maximumClockSkewMs = maximumClockSkewMs
    }

    public mutating func validate(nonce: Data, timestampUnixMs: Int64, sequence: UInt64, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws {
        if abs(nowUnixMs - timestampUnixMs) > maximumClockSkewMs { throw WireError.staleTimestamp }
        if seenNonces.contains(nonce) { throw WireError.replayDetected }
        if hasSequence && sequence <= highestSequence { throw WireError.sequenceRollback }
        seenNonces.insert(nonce)
        highestSequence = sequence
        hasSequence = true
    }
}
