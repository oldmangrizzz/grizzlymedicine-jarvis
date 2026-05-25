import XCTest
@testable import JARVISWatchCompanion

final class WatchCompanionLogicTests: XCTestCase {
    func testSiriWatchFaceGateDefaultsToNotAcknowledged() {
        let defaults = UserDefaults(suiteName: "jarvis.watch.tests.")!
        defaults.removeObject(forKey: SiriWatchFaceGate.acknowledgementKey)
        XCTAssertFalse(SiriWatchFaceGate.current(defaults: defaults).isAcknowledged)
    }

    func testSiriWatchFaceGateAcknowledgementPersists() {
        let defaults = UserDefaults(suiteName: "jarvis.watch.tests.")!
        defaults.removeObject(forKey: SiriWatchFaceGate.acknowledgementKey)
        SiriWatchFaceGate.acknowledgeRemoved(defaults: defaults)
        XCTAssertTrue(SiriWatchFaceGate.current(defaults: defaults).isAcknowledged)
    }
}
