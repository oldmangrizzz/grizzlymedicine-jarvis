import AVFoundation
import JARVISCompanionCore
import Speech
import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @EnvironmentObject private var accent: CompanionAccentTheme
    @StateObject private var voice = VoiceCommandViewModel()
    @StateObject private var health = HealthContextViewModel()
    @State private var typedFallback: String = ""
    @State private var showTouchFallback = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, accent.color.opacity(0.14), accent.color.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        voiceSurface
                        if !accent.hasChosenAccent {
                            accentOnboarding
                        }
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
                await appState.checkConnection()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                BrandSealView(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GMRI COMPANION OS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(1.4)
                        .foregroundStyle(accent.color.opacity(0.90))
                    Text("JARVIS")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, accent.color.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                Spacer()
                StatePill(
                    title: appState.isPaired ? "Ready" : "Connecting",
                    systemImage: appState.isPaired ? "checkmark.seal.fill" : "wifi.exclamationmark",
                    tint: appState.isPaired ? .green : .orange
                )
            }

            Text("Tap the highlight circle. Speak normally. Tap it again when you are done.")
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
                    VoiceOrb(accent: accent.color, isListening: voice.isListening, isThinking: appState.isCommandInFlight || voice.isTranscribing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.isListening ? "Stop recording and execute command" : "Start recording JARVIS command")

                Text(voicePrompt)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                Text("Ask for a website, video, music, directions, emergency info, or anything JARVIS should handle.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.58))

                if !voice.transcript.isEmpty {
                    TranscriptBlock(title: "You", text: voice.transcript, tint: accent.color)
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

    private var accentOnboarding: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose your highlight color")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Say \"JARVIS, my color is green\" or tap a color. This becomes your personal visual cue here and later in glasses mode.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                AccentChoiceGrid { hue in
                    accent.choose(hue)
                    Task {
                        await appState.acknowledgeLocalCommand(
                            "Highlight color",
                            reply: "Done. Your highlight color is \(hue.label)."
                        )
                    }
                }
            }
        }
    }

    private var visionSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What JARVIS is doing")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(accent.color)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                SignalCard(title: "Connection", value: appState.connectionStatus, systemImage: "cloud.fill", tint: appState.isPaired ? .green : .orange)
                SignalCard(title: "JARVIS", value: appState.isCommandInFlight ? "Answering now" : "Ready", systemImage: "sparkles", tint: accent.color)
            }

            if !appState.lastCommand.isEmpty {
                TranscriptBlock(title: "Last command", text: appState.lastCommand, tint: accent.color)
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
                connectionRecovery
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
            Label("Can't talk? Type instead.", systemImage: "keyboard")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tint(accent.color)
    }

    private var healthSurface: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Emergency info", systemImage: "heart.text.square.fill")
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
                        Label("Speak emergency info", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !health.errorText.isEmpty {
                    RecoveryBlock(text: health.errorText)
                }
            }
        }
    }

    private var connectionRecovery: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connecting to JARVIS", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This should happen by itself. If it does not, tap Try again.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                Button {
                    Task { await appState.registerDevice() }
                } label: {
                    Label(appState.isConnecting ? "Trying now" : "Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isConnecting)
            }
        }
    }

    private var voicePrompt: String {
        if appState.isCommandInFlight {
            return "JARVIS is answering."
        }
        if appState.isConnecting {
            return "Getting JARVIS ready."
        }
        if voice.isTranscribing {
            return "Turning your voice into a command."
        }
        if voice.isListening {
            return "Listening. Tap again when done."
        }
        if !appState.isPaired {
            return "Getting ready. You should not need setup."
        }
        return "Tap the highlight circle and talk."
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
        if let hue = accent.choose(fromSpeech: text) {
            await appState.acknowledgeLocalCommand(
                text,
                reply: "Done. Your highlight color is \(hue.label)."
            )
            return
        }
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
    let accent: Color
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
            return accent
        }
        return accent
    }

    private var orbColors: [Color] {
        if isThinking {
            return [accent.opacity(0.95), .white.opacity(0.22), .black.opacity(0.15)]
        }
        if isListening {
            return [accent.opacity(0.95), accent.opacity(0.58), .black.opacity(0.20)]
        }
        return [accent.opacity(0.92), accent.opacity(0.38), .black.opacity(0.24)]
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
    @EnvironmentObject private var accent: CompanionAccentTheme
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
                    .stroke(accent.color.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct AccentChoiceGrid: View {
    let choose: (CompanionAccentHue) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 78), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(CompanionAccentHue.allCases) { hue in
                Button {
                    choose(hue)
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(hue.color)
                            .frame(width: 22, height: 22)
                        Text(hue.label)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(hue.color.opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
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
