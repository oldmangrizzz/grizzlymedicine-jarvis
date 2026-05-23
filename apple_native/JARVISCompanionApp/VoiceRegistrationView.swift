import AVFoundation
import JARVISCompanionCore
import SwiftUI

struct VoiceRegistrationView: View {
    @StateObject private var model = VoiceRegistrationViewModel.make()

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    Picker("Save voice for", selection: $model.selectedPersonID) {
                        Text("Choose person").tag(Optional<UUID>.none)
                        ForEach(model.people) { person in
                            Text(person.displayName).tag(Optional(person.id))
                        }
                    }
                    Button("Refresh list") {
                        Task { await model.refresh() }
                    }
                }

                Section("Voice samples") {
                    Text("\(model.sampleCount) samples captured")
                    Text(model.instruction)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if model.isRecording {
                        Button("Stop recording") {
                            Task { await model.stopRecording() }
                        }
                        .foregroundStyle(.red)
                    } else {
                        Button("Record sample") {
                            Task { await model.startRecording() }
                        }
                    }
                }

                if !model.message.isEmpty {
                    Section("Status") {
                        Text(model.message)
                    }
                }

                if !model.errorText.isEmpty {
                    Section("Needs attention") {
                        Text(model.errorText)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("My Voice")
            .task { await model.refresh() }
        }
    }
}

@MainActor
final class VoiceRegistrationViewModel: ObservableObject {
    @Published var people: [AuthorizedPerson] = []
    @Published var selectedPersonID: UUID? {
        didSet {
            sampleCount = countSamples(for: selectedPersonID)
        }
    }
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var message: String = ""
    @Published private(set) var errorText: String = ""

    let instruction = "Capture three short, consented samples in a quiet room. These samples are for recognizing the tester; they do not change JARVIS's spoken voice."

    private let store: OnboardingStore?
    private var recorder: AVAudioRecorder?
    private var currentRecordingURL: URL?

    static func make() -> VoiceRegistrationViewModel {
        do {
            return try VoiceRegistrationViewModel()
        } catch {
            return VoiceRegistrationViewModel(errorText: "Could not open onboarding store: \(error)")
        }
    }

    init() throws {
        self.store = try OnboardingStore(fileURL: OnboardingStore.defaultFileURL())
    }

    private init(errorText: String) {
        self.store = nil
        self.errorText = errorText
    }

    func refresh() async {
        guard let store else {
            return
        }
        let state = await store.snapshot()
        people = state.persons.filter { $0.revokedAt == nil }
        if selectedPersonID == nil {
            selectedPersonID = people.first?.id
        }
        sampleCount = countSamples(for: selectedPersonID)
    }

    func startRecording() async {
        guard let personID = selectedPersonID else {
            errorText = "Add a trusted person before recording voice samples."
            return
        }
        guard !isRecording else {
            return
        }

        do {
            let granted = await requestMicrophoneAccess()
            guard granted else {
                errorText = "Microphone permission is required for voice registration."
                return
            }

            let directory = try sampleDirectory(for: personID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).m4a")

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else {
                throw VoiceRegistrationError.recordingDidNotStart
            }

            recorder = newRecorder
            currentRecordingURL = url
            isRecording = true
            message = "Recording. Speak a short natural phrase, then stop."
            errorText = ""
        } catch {
            isRecording = false
            recorder = nil
            currentRecordingURL = nil
            errorText = "Recording failed: \(error)"
        }
    }

    func stopRecording() async {
        guard isRecording else {
            return
        }
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recorder = nil
        isRecording = false

        guard let url = currentRecordingURL, let personID = selectedPersonID else {
            currentRecordingURL = nil
            return
        }
        currentRecordingURL = nil

        do {
            let count = countSamples(for: personID)
            guard count > 0, FileManager.default.fileExists(atPath: url.path) else {
                throw VoiceRegistrationError.sampleMissing
            }
            guard let store else {
                throw VoiceRegistrationError.storeUnavailable
            }
            _ = try await store.updateVoiceEnrollment(
                personID: personID,
                status: .samplesCapturedPendingModel(sampleCount: count)
            )
            await refresh()
            message = "\(count) voice sample\(count == 1 ? "" : "s") captured. Model enrollment is pending."
            errorText = ""
        } catch {
            errorText = "Could not save voice sample status: \(error)"
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func countSamples(for personID: UUID?) -> Int {
        guard let personID,
              let directory = try? sampleDirectory(for: personID),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else {
            return 0
        }
        return files.filter { $0.pathExtension.lowercased() == "m4a" }.count
    }

    private func sampleDirectory(for personID: UUID) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("JARVISCompanion", isDirectory: true)
            .appendingPathComponent("VoiceSamples", isDirectory: true)
            .appendingPathComponent(personID.uuidString.lowercased(), isDirectory: true)
    }
}

private enum VoiceRegistrationError: Error {
    case recordingDidNotStart
    case sampleMissing
    case storeUnavailable
}
