import Foundation
import HealthKit
import JARVISCompanionCore

struct HealthSnapshot: Equatable, Sendable {
    var authorized: Bool = false
    var updatedAt: Date = Date()
    var heartRateBPM: Double?
    var hrvSDNNMilliseconds: Double?
    var oxygenSaturationPercent: Double?
    var stepCountToday: Double?

    var statusLine: String {
        guard authorized else {
            return "HealthKit not authorized"
        }
        var parts: [String] = []
        if let heartRateBPM {
            parts.append("HR \(Int(heartRateBPM.rounded())) bpm")
        }
        if let hrvSDNNMilliseconds {
            parts.append("HRV \(Int(hrvSDNNMilliseconds.rounded())) ms")
        }
        if let oxygenSaturationPercent {
            parts.append("SpO2 \(Int(oxygenSaturationPercent.rounded()))%")
        }
        if let stepCountToday {
            parts.append("\(Int(stepCountToday.rounded())) steps today")
        }
        return parts.isEmpty ? "Authorized; no recent samples" : parts.joined(separator: " · ")
    }

    var emsBriefing: String {
        var lines = [
            "This is JARVIS, Robert Hanson's GMRI companion.",
            "Robert may use this device as a communication and accessibility prosthetic.",
            "I can provide observable device context, not a diagnosis."
        ]
        if authorized {
            lines.append("Latest authorized HealthKit context: \(statusLine).")
        } else {
            lines.append("HealthKit context is not authorized on this device.")
        }
        lines.append("Use standard EMS assessment and Robert's Medical ID for clinical decisions.")
        return lines.joined(separator: " ")
    }

    var json: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "authorized": .bool(authorized),
            "updated_at": .number(updatedAt.timeIntervalSince1970),
            "status": .string(statusLine),
        ]
        if let heartRateBPM {
            out["heart_rate_bpm"] = .number(heartRateBPM)
        }
        if let hrvSDNNMilliseconds {
            out["hrv_sdnn_ms"] = .number(hrvSDNNMilliseconds)
        }
        if let oxygenSaturationPercent {
            out["oxygen_saturation_percent"] = .number(oxygenSaturationPercent)
        }
        if let stepCountToday {
            out["step_count_today"] = .number(stepCountToday)
        }
        return out
    }
}

@MainActor
final class HealthContextViewModel: ObservableObject {
    @Published private(set) var snapshot = HealthSnapshot()
    @Published private(set) var errorText = ""
    @Published private(set) var isRefreshing = false

    private let store = HKHealthStore()

    var canReadHealthData: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func refresh() async {
        guard canReadHealthData else {
            snapshot = HealthSnapshot(authorized: false)
            errorText = "Health data is not available on this device."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await requestAuthorization()
            async let heartRate = latestQuantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()))
            async let hrv = latestQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
            async let oxygenFraction = latestQuantity(.oxygenSaturation, unit: .percent())
            async let steps = todaySum(.stepCount, unit: .count())
            let oxygen = try await oxygenFraction.map { $0 * 100.0 }
            snapshot = HealthSnapshot(
                authorized: true,
                updatedAt: Date(),
                heartRateBPM: try await heartRate,
                hrvSDNNMilliseconds: try await hrv,
                oxygenSaturationPercent: oxygen,
                stepCountToday: try await steps
            )
            errorText = ""
        } catch {
            snapshot = HealthSnapshot(authorized: false)
            errorText = "HealthKit read failed: \(error.localizedDescription)"
        }
    }

    static func isEMSCommand(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("ems") ||
            lower.contains("paramedic") ||
            lower.contains("medical briefing") ||
            lower.contains("emergency briefing")
    }

    private func requestAuthorization() async throws {
        let readTypes = Set(quantityTypes.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthContextError.authorizationDenied)
                }
            }
        }
    }

    private var quantityTypes: [HKQuantityTypeIdentifier] {
        [.heartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .stepCount]
    }

    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func todaySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}

private enum HealthContextError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        "HealthKit authorization was not granted."
    }
}
