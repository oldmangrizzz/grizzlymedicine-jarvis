import AVFoundation
import JARVISCompanionCore
import Speech
import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @StateObject private var voice = VoiceCommandViewModel()
    @StateObject private var health = HealthContextViewModel()
    @State private var typedFallback: String = ""
    @State private var showTouchFallback = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.02, green: 0.06, blue: 0.10), Color(red: 0.00, green: 0.15, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        voiceSurface
                        visionSurface
                        healthSurface
                        touchFallback
                    }
                    .padding(20)
                }
            }
            .navigationTitle("JARVIS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                if appState.isPaired {
                    await appState.checkConnection()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GMRI COMPANION OS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(1.4)
                        .foregroundStyle(.cyan.opacity(0.90))
                    Text("JARVIS")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .cyan.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                Spacer()
                StatePill(
                    title: appState.isPaired ? "Paired" : "Pair",
                    systemImage: appState.isPaired ? "checkmark.seal.fill" : "link.badge.plus",
                    tint: appState.isPaired ? .green : .orange
                )
            }

            Text("Hands, eyes, and ears for the digital world. Speak naturally; JARVIS acts through the device and answers live.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.74))
        }
        .padding(.top, 8)
    }

    private var voiceSurface: some View {
        GlassPanel {
            VStack(spacing: 18) {
                Button {
                    Task { await toggleVoice() }
                } label: {
                    VoiceOrb(isListening: voice.isListening, isThinking: appState.isCommandInFlight || voice.isTranscribing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.isListening ? "Stop recording and execute command" : "Start recording JARVIS command")

                Text(voicePrompt)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                if !voice.transcript.isEmpty {
                    TranscriptBlock(title: "You", text: voice.transcript, tint: .cyan)
                }

                if !voice.errorText.isEmpty {
                    RecoveryBlock(text: voice.errorText)
                }

                HStack(spacing: 8) {
                    CapabilityChip(title: "Web", systemImage: "safari")
                    CapabilityChip(title: "Video", systemImage: "play.rectangle")
                    CapabilityChip(title: "Music", systemImage: "music.note")
                    CapabilityChip(title: "Maps", systemImage: "map")
                }
            }
        }
    }

    private var visionSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operational field")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.cyan)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                SignalCard(title: "Cloud", value: appState.connectionStatus, systemImage: "cloud.fill", tint: appState.isPaired ? .green : .orange)
                SignalCard(title: "Runtime", value: appState.isCommandInFlight ? "Live command in progress" : "Ready for command", systemImage: "sparkles", tint: .cyan)
            }

            if !appState.lastCommand.isEmpty {
                TranscriptBlock(title: "Last command", text: appState.lastCommand, tint: .blue)
            }

            if !appState.lastDeviceAction.isEmpty {
                TranscriptBlock(title: "Device", text: appState.lastDeviceAction, tint: .purple)
            }

            if !appState.lastReply.isEmpty {
                TranscriptBlock(title: "JARVIS", text: appState.lastReply, tint: .green)
            }

            if !appState.lastError.isEmpty {
                RecoveryBlock(text: appState.lastError)
            }

            if !appState.isPaired {
                inlinePairing
            }
        }
    }

    private var touchFallback: some View {
        DisclosureGroup(isExpanded: $showTouchFallback) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Type only if voice is unavailable", text: $typedFallback, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let text = typedFallback
                    typedFallback = ""
                    Task { await appState.sendTurn(text) }
                } label: {
                    Label("Send fallback text", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(typedFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 10)
        } label: {
            Label("Manual fallback", systemImage: "hand.tap")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tint(.cyan)
    }

    private var healthSurface: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("HealthKit and EMS context", systemImage: "heart.text.square.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(health.snapshot.statusLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.76))
                HStack {
                    Button {
                        Task {
                            await health.refresh()
                            await appState.publishHealthSnapshot(health.snapshot, reason: "manual_refresh")
                        }
                    } label: {
                        Label(health.isRefreshing ? "Reading" : "Refresh", systemImage: "heart.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(health.isRefreshing)

                    Button {
                        Task {
                            await health.refresh()
                            await appState.speakHealthBriefing(health.snapshot)
                        }
                    } label: {
                        Label("Speak EMS briefing", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !health.errorText.isEmpty {
                    RecoveryBlock(text: health.errorText)
                }
            }
        }
    }

    private var inlinePairing: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pair this device", systemImage: "link.badge.plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Enter the short pairing code. No laptop IP address. No Mac bridge token.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                TextField("Pairing code", text: $appState.pairingCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await appState.pairDevice() }
                } label: {
                    Label("Pair with JARVIS Cloud", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var voicePrompt: String {
        if appState.isCommandInFlight {
            return "Live command in progress."
        }
        if voice.isTranscribing {
            return "Transcribing command."
        }
        if voice.isListening {
            return "Recording. Tap again to execute."
        }
        if !appState.isPaired {
            return "Pair once, then speak."
        }
        return "Tap the orb and speak."
    }

    private func toggleVoice() async {
        if voice.isListening {
            let text = await voice.stopAndTranscribe()
            await executeSpokenCommand(text)
        } else {
            await voice.startListening()
        }
    }

    private func executeSpokenCommand(_ text: String) async {
        if HealthContextViewModel.isEMSCommand(text) {
            await health.refresh()
            await appState.speakHealthBriefing(health.snapshot)
            return
        }
        await appState.sendTurn(text)
    }
}

@MainActor
final class VoiceCommandViewModel: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var errorText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recognitionTask: SFSpeechRecognitionTask?

    func startListening() async {
        guard !isListening, !isTranscribing else {
            return
        }

        errorText = ""
        transcript = ""
        recognitionTask?.cancel()
        recognitionTask = nil

        guard await requestSpeechAccess() else {
            errorText = "Speech recognition permission is required for voice control."
            return
        }
        guard await requestMicrophoneAccess() else {
            errorText = "Microphone permission is required for voice control."
            return
        }
        guard recognizer != nil else {
            errorText = "Speech recognition is not available on this device."
            return
        }

        do {
            try configureAudioSession()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("jarvis-command-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                throw VoiceCommandError.recordingDidNotStart
            }
            self.recorder = recorder
            recordingURL = url
            isListening = true
        } catch {
            cleanupRecording()
            errorText = "Voice recording failed: \(error.localizedDescription)"
        }
    }

    func stopAndTranscribe() async -> String {
        guard isListening else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        recorder?.stop()
        recorder = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = recordingURL else {
            errorText = "No voice recording was captured."
            return ""
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            cleanupRecording()
        }

        do {
            let text = try await transcribe(url: url)
            transcript = text
            return text
        } catch {
            errorText = "Voice transcription failed: \(error.localizedDescription)"
            return ""
        }
    }

    private func transcribe(url: URL) async throws -> String {
        guard let recognizer else {
            throw VoiceCommandError.speechUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal, !resumed {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    return
                }
                if let error, !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cleanupRecording() {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
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
}

private enum VoiceCommandError: LocalizedError {
    case recordingDidNotStart
    case speechUnavailable

    var errorDescription: String? {
        switch self {
        case .recordingDidNotStart:
            return "The microphone did not start recording."
        case .speechUnavailable:
            return "Speech recognition is not available on this device."
        }
    }
}

private struct VoiceOrb: View {
    let isListening: Bool
    let isThinking: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: orbColors,
                        center: .center,
                        startRadius: 4,
                        endRadius: 150
                    )
                )
                .frame(width: 190, height: 190)
                .shadow(color: orbTint.opacity(0.65), radius: isListening ? 30 : 18)

            Circle()
                .stroke(.white.opacity(0.28), lineWidth: 1)
                .frame(width: 210, height: 210)

            Image(systemName: isThinking ? "sparkles" : (isListening ? "waveform" : "mic.fill"))
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var orbTint: Color {
        if isThinking {
            return .purple
        }
        return isListening ? .cyan : .blue
    }

    private var orbColors: [Color] {
        if isThinking {
            return [.purple.opacity(0.95), .cyan.opacity(0.50), .black.opacity(0.15)]
        }
        if isListening {
            return [.cyan.opacity(0.95), .blue.opacity(0.70), .black.opacity(0.20)]
        }
        return [.blue.opacity(0.95), .cyan.opacity(0.42), .black.opacity(0.24)]
    }
}

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct TranscriptBlock: View {
    let title: String
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(tint)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SignalCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.74))
            Text(value)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct StatePill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct CapabilityChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.cyan.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct RecoveryBlock: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
    }
}
