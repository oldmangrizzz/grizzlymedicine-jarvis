import AVFoundation
import Darwin
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftUI

struct AuthorizedSpeaker: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var relationship: String
    var enrolledAt: Date
    var lastHeardAt: Date?
    var permissions: [String]
    var voiceSHA256: String

    var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

@MainActor
final class AuthorizedSpeakersViewModel: ObservableObject {
    @Published private(set) var speakers: [AuthorizedSpeaker] = []
    @Published var status = "Add family members JARVIS should recognize."
    @Published var showingEnrollment = false
    @Published var removing: AuthorizedSpeaker?

    private let store = AuthorizedSpeakerStore()

    init() { reload() }

    func reload() {
        do { speakers = try store.loadSpeakers().sorted { $0.enrolledAt < $1.enrolledAt }; status = speakers.isEmpty ? "No family members added yet." : "JARVIS knows \(speakers.count) voice\(speakers.count == 1 ? "" : "s")." }
        catch {
            JARVISLog.error(subsystem: "speakers", event: "read_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            status = "Speaker list unavailable: \(operatorMessage(.internalError))"
        }
    }

    func save(name: String, relationship: String, recordingURL: URL) async -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { status = "Please type their name."; return false }
        guard await OperatorTouchID.confirm(reason: "Add \(cleanName) as someone JARVIS recognizes?") else { status = "Touch ID did not approve adding \(cleanName)."; return false }
        do {
            _ = try store.enroll(name: cleanName, relationship: relationship.trimmingCharacters(in: .whitespacesAndNewlines), recordingURL: recordingURL)
            status = "JARVIS now knows \(cleanName)'s voice."
            reload()
            return true
        } catch AuthorizedSpeakerStoreError.auditKeyMissing {
            status = "This action requires a completed ceremony — please complete soul anchor before adding authorized speakers."
            return false
        } catch {
            status = "Voice enroll failed for \(cleanName): \(operatorMessage(.writeFailed))"
            JARVISLog.error(subsystem: "speakers", event: "enroll_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            return false
        }
    }

    func remove(_ speaker: AuthorizedSpeaker, typedName: String) async {
        guard typedName.trimmingCharacters(in: .whitespacesAndNewlines) == speaker.name else { status = "Type \(speaker.name) to remove them."; return }
        guard await OperatorTouchID.confirm(reason: "Remove \(speaker.name) from voices JARVIS recognizes?") else { status = "Touch ID did not approve removing \(speaker.name)."; return }
        do { try store.remove(speaker); removing = nil; status = "JARVIS no longer recognizes \(speaker.name)'s voice from this Mac."; reload() }
        catch {
            JARVISLog.error(subsystem: "speakers", event: "remove_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            status = "Speaker remove failed: \(operatorMessage(.writeFailed))"
        }
    }
}

struct AuthorizedSpeakersPanel: View {
    @StateObject private var model = AuthorizedSpeakersViewModel()

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("People JARVIS recognizes", systemImage: "person.2.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(GMRITheme.color.neutral)
                    Spacer()
                    Button { model.showingEnrollment = true } label: {
                        Label("Add a person", systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("JARVIS can listen and speak with each person here. Only Robert can change JARVIS's identity.")
                    .font(.callout)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
                if model.speakers.isEmpty {
                    Text("No one has been added yet.")
                        .font(.title3)
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.speakers) { speaker in
                        SpeakerRow(speaker: speaker) { model.removing = speaker }
                    }
                }
                Text(model.status).font(.callout).foregroundStyle(GMRITheme.color.warning).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $model.showingEnrollment) { EnrollmentFlow(model: model) }
        .sheet(item: $model.removing) { speaker in RemoveSpeakerSheet(model: model, speaker: speaker) }
    }
}

private struct SpeakerRow: View {
    let speaker: AuthorizedSpeaker
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack { Circle().fill(GMRITheme.color.success.opacity(0.25)); Text(speaker.initials).font(.title2.bold()).foregroundStyle(GMRITheme.color.neutral) }
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(speaker.name).font(.title3.weight(.semibold)).foregroundStyle(GMRITheme.color.neutral)
                Text(speaker.relationship.isEmpty ? "Family" : speaker.relationship).font(.callout).foregroundStyle(GMRITheme.color.neutral.opacity(0.7))
                Text("Added \(speaker.enrolledAt.formatted(date: .abbreviated, time: .omitted)) · Last heard \(speaker.lastHeardAt?.formatted(date: .abbreviated, time: .shortened) ?? "not yet")")
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.56))
            }
            Spacer()
            Button(role: .destructive, action: remove) { Text("Remove").font(.headline).padding(.horizontal, 10).padding(.vertical, 6) }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(GMRITheme.color.neutral.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct EnrollmentFlow: View {
    @ObservedObject var model: AuthorizedSpeakersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var relationship = ""
    @State private var step = 1
    @StateObject private var recorder = SpeakerVoiceRecorder()
    @State private var message = ""
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(GMRITheme.color.neutral)
            if step == 1 {
                TextField("Their name", text: $name).textFieldStyle(.roundedBorder).font(.title2)
                TextField("Who they are to you", text: $relationship).textFieldStyle(.roundedBorder).font(.title2)
                Button("Next") { step = 2 }.buttonStyle(.borderedProminent).font(.title3).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if step == 2 {
                Text("Pass the Mac to \(name). They'll record their voice next.").font(.title2).foregroundStyle(GMRITheme.color.neutral)
                Button("Ready to record") { step = 3 }.buttonStyle(.borderedProminent).font(.title3)
            } else if step == 3 {
                Text(SpeakerScript.script(name: name, operatorName: NSFullUserName()))
                    .font(.title3).foregroundStyle(GMRITheme.color.neutral).padding().background(GMRITheme.color.background.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
                HStack(spacing: 20) {
                    Button { Task { await toggleRecording() } } label: {
                        ZStack { Circle().fill(recorder.isRecording ? GMRITheme.color.danger : GMRITheme.color.success).frame(width: 140, height: 140); Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill").font(.system(size: 52, weight: .bold)).foregroundStyle(GMRITheme.color.neutral) }
                    }.buttonStyle(.plain)
                    WaveLine(level: recorder.level)
                }
                if let url = recorder.lastRecordingURL, !recorder.isRecording {
                    HStack {
                        Button("Play it back") { play(url) }.buttonStyle(.bordered).font(.title3)
                        Button("Sounds good — keep it") { Task { await keep(url) } }.buttonStyle(.borderedProminent).font(.title3)
                        Button("Try again") { recorder.discard(); message = "Let's try again." }.buttonStyle(.bordered).font(.title3)
                    }
                }
            } else {
                Text("JARVIS now knows \(name)'s voice.").font(.title).foregroundStyle(GMRITheme.color.success)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).font(.title3)
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(GMRITheme.color.warning) }
        }
        .padding(28)
        .frame(width: 720, height: 620)
        .background(GMRITheme.color.background)
    }

    private var title: String {
        switch step { case 1: return "Add a person"; case 2: return "Hand the Mac over"; case 3: return "JARVIS is learning \(name)'s voice"; default: return "All set" }
    }

    private func toggleRecording() async {
        do { recorder.isRecording ? recorder.stop() : try await recorder.start(); message = "" }
        catch SpeakerVoiceError.microphoneDenied { message = "JARVIS needs to hear them. Please allow microphone access in System Settings." }
        catch SpeakerVoiceError.recordingDidNotStart { message = "The microphone did not begin recording. Please check the input device and try again." }
        catch { message = "The microphone did not start. Let's try again." }
    }

    private func keep(_ url: URL) async {
        do {
            switch try recorder.validateLastRecording() {
            case .ok:
                if await model.save(name: name, relationship: relationship, recordingURL: url) { step = 4 }
            case .tooQuiet: message = "I couldn't hear them clearly. Let's try again in a quieter spot."
            case .clipped: message = "That was a bit loud — let's try again a little softer."
            }
        } catch SpeakerVoiceError.tooShort { message = "Please record at least twenty-five seconds so JARVIS has enough of their voice." }
        catch { message = "JARVIS could not read that recording. Let's try again." }
    }

    private func play(_ url: URL) { do { player = try AVAudioPlayer(contentsOf: url); player?.play() } catch { message = "Playback did not start. You can try again." } }
}

private struct RemoveSpeakerSheet: View {
    @ObservedObject var model: AuthorizedSpeakersViewModel
    let speaker: AuthorizedSpeaker
    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove \(speaker.name)?").font(.title.bold())
            Text("Type \(speaker.name), then use Touch ID. This prevents accidental removals.")
            TextField(speaker.name, text: $typedName).textFieldStyle(.roundedBorder).font(.title2)
            HStack { Button("Cancel") { dismiss() }; Button(role: .destructive) { Task { await model.remove(speaker, typedName: typedName); dismiss() } } label: { Text("Remove") }.disabled(typedName != speaker.name) }
        }.padding(28).frame(width: 520).background(GMRITheme.color.background).foregroundStyle(GMRITheme.color.neutral)
    }
}

private enum SpeakerValidation { case ok, tooQuiet, clipped }
private enum SpeakerVoiceError: Error { case microphoneDenied, tooShort, recordingDidNotStart }

enum AuthorizedSpeakerStoreError: Error, LocalizedError, Equatable {
    case auditKeyMissing(reason: String)
    case invalidLegacyAuditKey(reason: String)
    case invalidAuditKeyLength(Int)
    case posix(context: String, errno: Int32)
    case keychain(status: OSStatus, context: String)
    case crypto(String)

    var errorDescription: String? {
        switch self {
        case .auditKeyMissing(let reason): return reason
        case .invalidLegacyAuditKey(let reason): return reason
        case .invalidAuditKeyLength(let count): return "authorized speaker audit key must be 32 bytes, got \(count)"
        case .posix(let context, let errno): return "\(context): errno=\(errno)"
        case .keychain(let status, let context): return "\(context): OSStatus=\(status)"
        case .crypto(let message): return message
        }
    }
}

@MainActor
private final class SpeakerVoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var level = 0.0
    @Published var lastRecordingURL: URL?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeakerVoiceError.microphoneDenied }
        default: throw SpeakerVoiceError.microphoneDenied
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("speaker-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("speaker-\(UUID().uuidString).wav")
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: 45) else {
            JARVISLog.warn(subsystem: "speakers", event: "recording_start_failed", fields: ["path": url.path])
            throw SpeakerVoiceError.recordingDidNotStart
        }
        self.recorder = recorder
        lastRecordingURL = url
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.recorder?.updateMeters(); let p = self?.recorder?.averagePower(forChannel: 0) ?? -80; self?.level = min(1, max(0, (Double(p) + 60) / 60)) } }
    }

    func stop() { recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil; isRecording = false }
    func discard() { stop(); if let lastRecordingURL { try? FileManager.default.removeItem(at: lastRecordingURL) }; lastRecordingURL = nil } // TODO(removal-cond: log discard failure as WRITE_FAILED once audit sink available in this scope)

    func validateLastRecording() throws -> SpeakerValidation {
        guard let url = lastRecordingURL else { throw SpeakerVoiceError.tooShort }
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        guard seconds >= 25 else { throw SpeakerVoiceError.tooShort }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return .tooQuiet }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return .tooQuiet }
        let count = Int(buffer.frameLength)
        var sum = 0.0; var clipped = 0
        for i in 0..<count { let x = Double(channel[i]); sum += x * x; if abs(x) >= 0.999 { clipped += 1 } }
        let rms = count == 0 ? 0 : sqrt(sum / Double(count))
        if rms < 0.015 { return .tooQuiet }
        if count > 0 && Double(clipped) / Double(count) > 0.05 { return .clipped }
        return .ok
    }
}

private struct WaveLine: View {
    let level: Double
    var body: some View { HStack(spacing: 4) { ForEach(0..<20, id: \.self) { i in Capsule().fill(GMRITheme.color.success).frame(width: 8, height: max(14, CGFloat(level * 70) + CGFloat((i % 5) * 7))) } }.frame(height: 100) }
}

private enum SpeakerScript {
    static func script(name: String, operatorName: String) -> String {
        "This is \(name). I'm recording this so JARVIS knows my voice. \(operatorName) has authorized me to be heard. JARVIS will recognize me when I speak, and refuse anyone who pretends to be me. Today is \(plainEnglishDate()). Voice anchor complete."
    }

    private static func plainEnglishDate(_ date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let monthFormatter = DateFormatter(); monthFormatter.locale = Locale(identifier: "en_US"); monthFormatter.dateFormat = "MMMM"
        let month = monthFormatter.string(from: date)
        let day = calendar.component(.day, from: date)
        let ordinals = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "twenty first", "twenty second", "twenty third", "twenty fourth", "twenty fifth", "twenty sixth", "twenty seventh", "twenty eighth", "twenty ninth", "thirtieth", "thirty first"]
        let year = calendar.component(.year, from: date)
        let yearText = NumberFormatter.localizedString(from: NSNumber(value: year), number: .spellOut).replacingOccurrences(of: "-", with: " ")
        return "\(month) \(day >= 1 && day < ordinals.count ? ordinals[day] : String(day)), \(yearText)"
    }
}

private enum OperatorTouchID {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in continuation.resume(returning: ok) } }
    }
}

final class AuthorizedSpeakerStore {
    private static let legacyCanary = Data("JARVIS-authorized-speakers-audit-key-canary-v1".utf8)

    /// Centralised HKDF domain strings for this store. Same purpose → same string.
    private enum HKDFDomain: String {
        case auditHmacKey = "jarvis.audit.hmacKey.v1"
    }

    private let root: URL
    private let auditKeyService: String
    private let auditKeyAccount: String
    private let legacyAuditKeyURL: URL
    private let ceremonyAuditSealBlobURL: URL
    private var voiceRoot: URL { root.appendingPathComponent("_local_voice", isDirectory: true) }
    private var speakersRoot: URL { voiceRoot.appendingPathComponent("speakers", isDirectory: true) }
    private var registryURL: URL { speakersRoot.appendingPathComponent("speakers.json") }
    private var sbomURL: URL { root.appendingPathComponent("apple_native/sbom/voice-weights-baseline.json") }
    private var auditURL: URL { root.appendingPathComponent("apple_native/JARVISNativeRuntime/integrity/audit/authorized_speakers.jsonl") }

    init(root: URL = AuthorizedSpeakerStore.defaultRoot(),
         auditKeyService: String = "org.gmri.jarvis.mac-cockpit.authorized-speakers.audit-hmac",
         auditKeyAccount: String = "authorized_speakers",
         legacyAuditKeyURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("research/jarvis/apple_native/JARVISNativeRuntime/integrity/audit/authorized_speakers.key"),
         ceremonyAuditSealBlobURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis/audit/seal_master.se.blob")) {
        self.root = root
        self.auditKeyService = auditKeyService
        self.auditKeyAccount = auditKeyAccount
        self.legacyAuditKeyURL = legacyAuditKeyURL
        self.ceremonyAuditSealBlobURL = ceremonyAuditSealBlobURL
    }

    private static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JARVIS", isDirectory: true)
    }

    func loadSpeakers() throws -> [AuthorizedSpeaker] {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AuthorizedSpeaker].self, from: Data(contentsOf: registryURL))
    }

    func enroll(name: String, relationship: String, recordingURL: URL) throws -> AuthorizedSpeaker {
        try FileManager.default.createDirectory(at: speakersRoot, withIntermediateDirectories: true)
        var speakers = try loadSpeakers()
        let id = UUID()
        let wavURL = speakersRoot.appendingPathComponent("\(id.uuidString).wav")
        if FileManager.default.fileExists(atPath: wavURL.path) { try FileManager.default.removeItem(at: wavURL) }
        try FileManager.default.copyItem(at: recordingURL, to: wavURL)
        let hash = try sha256(wavURL)
        let speaker = AuthorizedSpeaker(id: id, name: name, relationship: relationship.isEmpty ? "family" : relationship, enrolledAt: Date(), lastHeardAt: nil, permissions: ["listen", "speak_with"], voiceSHA256: hash)
        speakers.append(speaker)
        try saveRegistry(speakers)
        try saveSidecar(speaker)
        try updateSBOM(path: "_local_voice/speakers/\(id.uuidString).wav", sha256: hash, remove: false)
        try appendAudit(kind: "SPEAKER_ENROLLED", speaker: speaker, fileHash: hash)
        return speaker
    }

    func remove(_ speaker: AuthorizedSpeaker) throws {
        let wavURL = speakersRoot.appendingPathComponent("\(speaker.id.uuidString).wav")
        if FileManager.default.fileExists(atPath: wavURL.path) { try FileManager.default.removeItem(at: wavURL) }
        let sidecarURL = speakersRoot.appendingPathComponent("\(speaker.id.uuidString).json")
        if FileManager.default.fileExists(atPath: sidecarURL.path) { try FileManager.default.removeItem(at: sidecarURL) }
        try saveRegistry(try loadSpeakers().filter { $0.id != speaker.id })
        try updateSBOM(path: "_local_voice/speakers/\(speaker.id.uuidString).wav", sha256: speaker.voiceSHA256, remove: true)
        try appendAudit(kind: "SPEAKER_REMOVED", speaker: speaker, fileHash: speaker.voiceSHA256)
    }

    private func saveRegistry(_ speakers: [AuthorizedSpeaker]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: speakersRoot, withIntermediateDirectories: true)
        try writeBlobAtomically0600(encoder.encode(speakers), to: registryURL)
    }

    private func saveSidecar(_ speaker: AuthorizedSpeaker) throws {
        let sidecar = speakersRoot.appendingPathComponent("\(speaker.id.uuidString).json")
        let payload: [String: Any] = ["uuid": speaker.id.uuidString, "name": speaker.name, "relationship": speaker.relationship, "enrolled_at": ISO8601DateFormatter().string(from: speaker.enrolledAt), "permissions": speaker.permissions, "sha256": speaker.voiceSHA256]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try writeBlobAtomically0600(data, to: sidecar)
    }

    private func updateSBOM(path: String, sha256: String, remove: Bool) throws {
        var object: [String: Any] = FileManager.default.fileExists(atPath: sbomURL.path) ? (try JSONSerialization.jsonObject(with: Data(contentsOf: sbomURL)) as? [String: Any] ?? [:]) : ["entries": []]
        var entries = object["entries"] as? [[String: Any]] ?? []
        entries.removeAll { ($0["path"] as? String) == path }
        if !remove { entries.append(["path": path, "sha256": sha256, "timestamp": ISO8601DateFormatter().string(from: Date()), "source": "operator-attested speaker enrollment"]) }
        object["entries"] = entries
        try FileManager.default.createDirectory(at: sbomURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeBlobAtomically0600(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: sbomURL)
    }

    private func appendAudit(kind: String, speaker: AuthorizedSpeaker, fileHash: String) throws {
        try FileManager.default.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = try auditKey()
        let previous = try previousAuditHMAC()
        let nameHash = SHA256.hash(data: Data(speaker.name.utf8)).map { String(format: "%02x", $0) }.joined()
        var payload: [String: Any] = [
            "event_kind": kind,
            "uuid": speaker.id.uuidString,
            "hashed_name": nameHash,
            "relationship": speaker.relationship,
            "file_hash": fileHash,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "operator_attestation": "Touch ID approved",
            "previous_hmac": previous
        ]
        let canonical = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: key).map { String(format: "%02x", $0) }.joined()
        payload["hmac"] = mac
        var lineData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        lineData.append(Data("\n".utf8))
        try appendLineOAppendFlock0600(lineData, to: auditURL)
    }

    func auditKey() throws -> SymmetricKey {
        if let keyData = try keychainAuditKey() {
            try validateAuditKeyLength(keyData)
            try deleteLegacyAuditKeyIfPresent()
            return SymmetricKey(data: keyData)
        }
        if FileManager.default.fileExists(atPath: ceremonyAuditSealBlobURL.path) {
            let data = try deriveCeremonyAuditKey()
            try storeAuditKeyInKeychain(data)
            try deleteLegacyAuditKeyIfPresent()
            return SymmetricKey(data: data)
        }
        if FileManager.default.fileExists(atPath: legacyAuditKeyURL.path) {
            let legacy = try verifiedLegacyAuditKey()
            try storeAuditKeyInKeychain(legacy)
            try deleteLegacyAuditKeyIfPresent()
            return SymmetricKey(data: legacy)
        }
        throw AuthorizedSpeakerStoreError.auditKeyMissing(reason: "ceremony audit key not present; cannot register speakers")
    }

    private func validateAuditKeyLength(_ data: Data) throws {
        guard data.count == 32 else { throw AuthorizedSpeakerStoreError.invalidAuditKeyLength(data.count) }
    }

    private func deriveCeremonyAuditKey() throws -> Data {
        guard SecureEnclave.isAvailable else {
            throw AuthorizedSpeakerStoreError.auditKeyMissing(reason: "ceremony audit key not present; cannot register speakers")
        }
        let blob = try Data(contentsOf: ceremonyAuditSealBlobURL)
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                       salt: Data("JARVIS-AuditHMAC-v1".utf8),
                                                       sharedInfo: Data(HKDFDomain.auditHmacKey.rawValue.utf8),
                                                       outputByteCount: 32)
        var data = Data()
        symmetric.withUnsafeBytes { raw in data.append(contentsOf: raw) }
        try validateAuditKeyLength(data)
        return data
    }

    private struct LegacyAuditKeyEnvelope: Decodable {
        let key_b64: String
        let canary_hmac_hex: String
    }

    private func verifiedLegacyAuditKey() throws -> Data {
        let envelope = try JSONDecoder().decode(LegacyAuditKeyEnvelope.self, from: Data(contentsOf: legacyAuditKeyURL))
        guard let key = Data(base64Encoded: envelope.key_b64) else {
            throw AuthorizedSpeakerStoreError.invalidLegacyAuditKey(reason: "legacy authorized-speaker audit key is not base64 encoded")
        }
        try validateAuditKeyLength(key)
        // Constant-time HMAC verification via CryptoKit.HMAC.isValidAuthenticationCode.
        // The stored hex is decoded to bytes so isValidAuthenticationCode can operate on
        // raw bytes — no string comparison, no early-exit on first differing character.
        guard let storedMAC = Self.unhexBytes(envelope.canary_hmac_hex),
              HMAC<SHA256>.isValidAuthenticationCode(storedMAC,
                                                     authenticating: Self.legacyCanary,
                                                     using: SymmetricKey(data: key)) else {
            throw AuthorizedSpeakerStoreError.invalidLegacyAuditKey(reason: "legacy authorized-speaker audit key canary HMAC mismatch")
        }
        return key
    }

    private static func unhexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return bytes
    }

    private func writeBlobAtomically0600(_ data: Data, to dest: URL) throws {
        let parent = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scratch = parent.appendingPathComponent(".\(dest.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).new")
        let fd = open(scratch.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker atomic write open", errno: errno) }
        var closeNeeded = true
        var scratchNeedsCleanup = true
        defer { if closeNeeded { close(fd) }; if scratchNeedsCleanup { unlink(scratch.path) } }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker atomic write", errno: errno)
                }
                guard written > 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker atomic write made no progress", errno: EIO) }
                remaining -= written
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker atomic write fsync", errno: errno) }
        guard close(fd) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker atomic write close", errno: errno) }
        closeNeeded = false
        guard rename(scratch.path, dest.path) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker atomic write rename", errno: errno) }
        scratchNeedsCleanup = false
        try fsyncDirectory(parent)
    }

    private func appendLineOAppendFlock0600(_ data: Data, to dest: URL) throws {
        guard data.count <= 512 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker audit record exceeds PIPE_BUF=512", errno: EMSGSIZE) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(dest.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker audit append open", errno: errno) }
        defer { close(fd) }
        try verify0600Owner(fd: fd, context: "authorized speaker audit append")
        guard flock(fd, LOCK_EX) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker audit append flock", errno: errno) }
        defer { _ = flock(fd, LOCK_UN) }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while true {
                let written = Darwin.write(fd, base, rawBuffer.count)
                if written < 0 && errno == EINTR { continue }
                guard written == rawBuffer.count else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker audit append single write", errno: written < 0 ? errno : EIO) }
                break
            }
        }
        guard fsync(fd) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker audit append fsync", errno: errno) }
    }

    private func fsyncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker directory fsync open", errno: errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "authorized speaker directory fsync", errno: errno) }
    }

    private func verify0600Owner(fd: Int32, context: String) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AuthorizedSpeakerStoreError.posix(context: "\(context) fstat", errno: errno) }
        guard st.st_uid == geteuid() else { throw AuthorizedSpeakerStoreError.crypto("\(context) owner mismatch") }
        guard (st.st_mode & 0o777) == 0o600 else { throw AuthorizedSpeakerStoreError.crypto("\(context) mode must be 0600") }
    }

    private func keychainAuditKey() throws -> Data? {
        var query = keychainBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AuthorizedSpeakerStoreError.keychain(status: status, context: "authorized speaker audit key read") }
        return data
    }

    func storeAuditKeyInKeychain(_ data: Data) throws {
        try validateAuditKeyLength(data)
        var query = keychainBaseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(keychainBaseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw AuthorizedSpeakerStoreError.keychain(status: updateStatus, context: "authorized speaker audit key update") }
            return
        }
        guard status == errSecSuccess else { throw AuthorizedSpeakerStoreError.keychain(status: status, context: "authorized speaker audit key store") }
    }

    private func keychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: auditKeyService,
            kSecAttrAccount as String: auditKeyAccount
        ]
    }

    private func deleteLegacyAuditKeyIfPresent() throws {
        guard FileManager.default.fileExists(atPath: legacyAuditKeyURL.path) else { return }
        try FileManager.default.removeItem(at: legacyAuditKeyURL)
    }

    private func previousAuditHMAC() throws -> String {
        guard FileManager.default.fileExists(atPath: auditURL.path) else { return String(repeating: "0", count: 64) }
        let text = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        guard let last = lines.last else { return String(repeating: "0", count: 64) }
        guard let data = String(last).data(using: .utf8) else { throw NSError(domain: "AuthorizedSpeakerStore", code: 8) }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let fields = object as? [String: Any],
              let hmac = fields["hmac"] as? String,
              hmac.count == 64,
              hmac.allSatisfy({ $0.isHexDigit }) else { throw NSError(domain: "AuthorizedSpeakerStore", code: 9) }
        return hmac
    }

    private func sha256(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
}

struct AuthorizedSpeakersSmoke {
    static func run() throws {
        let script = SpeakerScript.script(name: "Alex", operatorName: "Robert Hanson")
        guard script.contains("JARVIS knows my voice"), script.contains("Robert Hanson has authorized me") else { throw NSError(domain: "AuthorizedSpeakersSmoke", code: 1) }
        let speaker = AuthorizedSpeaker(id: UUID(), name: "Alex Hanson", relationship: "son", enrolledAt: Date(), lastHeardAt: nil, permissions: ["listen", "speak_with"], voiceSHA256: String(repeating: "a", count: 64))
        guard speaker.permissions == ["listen", "speak_with"], speaker.initials == "AH" else { throw NSError(domain: "AuthorizedSpeakersSmoke", code: 2) }
        try auditKeyMissingThrows()
        try keychainAuditKeyReturns()
        try legacyInvalidHMACRefuses()
    }

    private struct Fixture {
        let root: URL
        let legacyURL: URL
        let service: String
        let account: String
        let store: AuthorizedSpeakerStore
    }

    private static func auditKeyMissingThrows() throws {
        let fixture = try fixtureStore()
        defer { cleanup(fixture) }
        do {
            _ = try fixture.store.auditKey()
            throw NSError(domain: "AuthorizedSpeakersSmoke", code: 3)
        } catch AuthorizedSpeakerStoreError.auditKeyMissing(let reason) {
            guard reason == "ceremony audit key not present; cannot register speakers" else { throw NSError(domain: "AuthorizedSpeakersSmoke", code: 4) }
        }
    }

    private static func keychainAuditKeyReturns() throws {
        let fixture = try fixtureStore()
        defer { cleanup(fixture) }
        let expected = Data((0..<32).map(UInt8.init))
        try fixture.store.storeAuditKeyInKeychain(expected)
        var actual = Data()
        try fixture.store.auditKey().withUnsafeBytes { raw in actual.append(contentsOf: raw) }
        guard actual == expected else { throw NSError(domain: "AuthorizedSpeakersSmoke", code: 5) }
    }

    private static func legacyInvalidHMACRefuses() throws {
        let fixture = try fixtureStore()
        defer { cleanup(fixture) }
        let payload: [String: String] = [
            "key_b64": Data(repeating: 0x42, count: 32).base64EncodedString(),
            "canary_hmac_hex": String(repeating: "0", count: 64)
        ]
        try FileManager.default.createDirectory(at: fixture.legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: fixture.legacyURL)
        do {
            _ = try fixture.store.auditKey()
            throw NSError(domain: "AuthorizedSpeakersSmoke", code: 6)
        } catch AuthorizedSpeakerStoreError.invalidLegacyAuditKey {
        }
    }

    private static func fixtureStore() throws -> Fixture {
        let service = "org.gmri.jarvis.mac-cockpit.authorized-speakers.audit-hmac.smoke.\(UUID().uuidString)"
        let account = "authorized_speakers_smoke"
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/authorized-speakers-smoke/\(UUID().uuidString)", isDirectory: true)
        let legacyURL = root.appendingPathComponent("legacy/authorized_speakers.key")
        let ceremonyURL = root.appendingPathComponent("missing/seal_master.se.blob")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        return Fixture(root: root,
                       legacyURL: legacyURL,
                       service: service,
                       account: account,
                       store: AuthorizedSpeakerStore(root: root,
                                                     auditKeyService: service,
                                                     auditKeyAccount: account,
                                                     legacyAuditKeyURL: legacyURL,
                                                     ceremonyAuditSealBlobURL: ceremonyURL))
    }

    private static func cleanup(_ fixture: Fixture) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: fixture.service, kSecAttrAccount as String: fixture.account] as CFDictionary)
        try? FileManager.default.removeItem(at: fixture.root) // TODO(removal-cond: fixture cleanup; test-only context, not production security path)
    }
}
