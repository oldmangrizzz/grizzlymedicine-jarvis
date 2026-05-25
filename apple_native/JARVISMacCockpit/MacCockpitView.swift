import SwiftUI
import CryptoKit

struct MacCockpitView: View {
    @EnvironmentObject private var httpService: NativeRuntimeHTTPServiceController
    @StateObject private var viewModel = MacCockpitViewModel()
    @StateObject private var convexWorker = NativeConvexWorkerService()
    @State private var typedCommand = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [GMRITheme.color.background, GMRITheme.color.success.opacity(0.12), GMRITheme.color.background, GMRITheme.color.danger.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    nativeStatus
                    CutoverPanel()
                    operatorHUD
                    transcriptPanel
                    auditPanel
                    httpServicePanel
                    convexWorkerPanel
                    AuthorizedSpeakersPanel()
                    voicePanel
                    textPanel
                    runtimePanel
                    if !viewModel.errorText.isEmpty {
                        RecoveryBlock(text: viewModel.errorText)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
            }
        }
        .frame(minWidth: 520, minHeight: 720)
        .task {
            viewModel.refreshState()
            convexWorker.start(runtime: viewModel.runtimeForServices, modelClient: viewModel.modelClientForServices)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                viewModel.refreshState()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            BrandSealView(size: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text("GMRI NATIVE RUNTIME")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(GMRITheme.color.success)
                Text("JARVIS")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(GMRITheme.color.neutral)
                Text("Swift cockpit. C++ runtime core. Operator-facing instrument surface.")
                    .font(.callout)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.68))
            }
            Spacer()
            StatePill(title: viewModel.isBusy ? "Thinking" : "Mounted", systemImage: "cpu.fill", tint: GMRITheme.color.success)
        }
    }

    private var nativeStatus: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label(viewModel.statusLine, systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.success)
                Text("This cockpit does not spawn `jarvis_bridge.py`, does not call Tauri, does not use Web Speech, and does not use a native system voice fallback.")
                    .font(.callout)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
                Text(viewModel.nativeConfigLine)
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.58))
            }
        }
    }


    private var operatorHUD: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Operator HUD", systemImage: "sensor.tag.radiowaves.forward.fill")
                        .font(.headline)
                        .foregroundStyle(GMRITheme.color.success)
                    Spacer()
                    StatePill(title: viewModel.mountLine, systemImage: "externaldrive.connected.to.line.below.fill", tint: viewModel.isMounted ? GMRITheme.color.success : GMRITheme.color.danger)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    GaugeCard(title: "Cortisol", value: viewModel.endocrineValue("cortisol"), tint: GMRITheme.color.success)
                    GaugeCard(title: "Dopamine", value: viewModel.endocrineValue("dopamine"), tint: GMRITheme.color.success)
                    GaugeCard(title: "Adrenaline", value: viewModel.endocrineValue("adrenaline"), tint: GMRITheme.color.danger)
                    GaugeCard(title: "Pheromind volatility", value: viewModel.pheromindVolatility, tint: GMRITheme.color.success)
                    GaugeCard(title: "Swarm activity", value: viewModel.swarmActivity, tint: GMRITheme.color.success)
                    GaugeCard(title: "CUSUM drift", value: viewModel.cusumDriftScore, tint: viewModel.cusumDriftScore < 0.35 ? GMRITheme.color.success : GMRITheme.color.danger)
                }
                HStack {
                    StatePill(title: viewModel.identityContinuityLine, systemImage: "person.text.rectangle.fill", tint: viewModel.identityContinuityOK ? GMRITheme.color.success : GMRITheme.color.danger)
                    StatePill(title: "Field signals \(viewModel.state?.field.count ?? 0)", systemImage: "wave.3.forward", tint: GMRITheme.color.success)
                    StatePill(title: "Audit \(viewModel.state?.auditCount ?? 0)", systemImage: "checklist.checked", tint: GMRITheme.color.danger)
                }
            }
        }
    }

    private var transcriptPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Redacted transcript", systemImage: "text.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.success)
                if viewModel.transcriptEntries.isEmpty {
                    Text("No turns committed in this cockpit session.")
                        .font(.caption)
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
                } else {
                    ForEach(viewModel.transcriptEntries) { entry in
                        TranscriptBlock(title: entry.role, text: entry.redactedText, tint: entry.role == "JARVIS" ? GMRITheme.color.success : GMRITheme.color.danger)
                    }
                }
            }
        }
    }

    private var auditPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Tamper-evident audit", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(GMRITheme.color.danger)
                    Spacer()
                    Button { viewModel.refreshAudit() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                if viewModel.auditEntries.isEmpty {
                    Text("No native HASP audit entries yet.")
                        .font(.caption)
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
                } else {
                    ForEach(viewModel.auditEntries.prefix(6)) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("#\(entry.id) \(entry.skill) — \(entry.decision)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(GMRITheme.color.neutral)
                                Text(entry.reason.isEmpty ? entry.argsPreview : entry.reason)
                                    .font(.caption2)
                                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.58))
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            StatePill(title: entry.risk, systemImage: entry.ok ? "checkmark.seal.fill" : "lock.fill", tint: entry.ok ? GMRITheme.color.success : GMRITheme.color.danger)
                        }
                        .padding(10)
                        .background(GMRITheme.color.neutral.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var httpServicePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label(httpService.status.message, systemImage: "network")
                    .font(.headline)
                    .foregroundStyle(httpService.status.state == .ready ? GMRITheme.color.success : GMRITheme.color.danger)
                Text("Local service: \(httpService.status.baseURLText) | companion token: \(httpService.status.companionTokenConfigured ? "configured" : "missing")")
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.68))
                Text(httpService.status.routeSummary)
                    .font(.caption2)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.52))
                    .textSelection(.enabled)
            }
        }
    }

    private var convexWorkerPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label(convexWorker.statusLine, systemImage: convexWorker.isEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.headline)
                    .foregroundStyle(convexWorker.isEnabled ? GMRITheme.color.success : GMRITheme.color.danger)
                Text("Native Swift worker publishes runtime memory/provenance state and completes Convex control requests without Python.")
                    .font(.callout)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
                HStack {
                    StatePill(title: "Pending \(convexWorker.pendingCount)", systemImage: "tray.full.fill", tint: GMRITheme.color.success)
                    StatePill(title: "Done \(convexWorker.processedCount)", systemImage: "checkmark.circle.fill", tint: GMRITheme.color.success)
                    StatePill(title: "Sync \(convexWorker.lastSyncText)", systemImage: "clock.fill", tint: GMRITheme.color.success)
                }
                Text(convexWorker.detailLine)
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
                    .textSelection(.enabled)
            }
        }
    }

    private var voicePanel: some View {
        GlassPanel {
            VStack(spacing: 16) {
                Button {
                    Task { await viewModel.toggleVoice() }
                } label: {
                    VoiceOrb(isListening: viewModel.isRecording, isThinking: viewModel.isBusy)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy)

                Text(viewModel.isRecording ? "Listening. Tap again when done." : "Tap the orb and speak.")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.neutral)

                if !viewModel.transcript.isEmpty {
                    TranscriptBlock(title: "You", text: viewModel.transcript, tint: GMRITheme.color.success)
                }
                if !viewModel.reply.isEmpty {
                    TranscriptBlock(title: "JARVIS", text: viewModel.reply, tint: GMRITheme.color.success)
                }

                VoicePathStatusBlock(
                    title: viewModel.voiceStatusLine,
                    detail: viewModel.voiceStatusDetail,
                    available: viewModel.voiceAvailable
                )
            }
        }
    }

    private var textPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard input")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.neutral)
                TextField("Type when you want silent input", text: $typedCommand, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let command = typedCommand
                    typedCommand = ""
                    Task { await viewModel.send(command) }
                } label: {
                    Label("Send to native runtime", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var runtimePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("Native UI spec")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.neutral)
                if let uiSpec = viewModel.uiSpec {
                    NativeUISpecSurface(spec: uiSpec)
                } else {
                    Text("UI spec not loaded.")
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.68))
                }
            }
        }
    }
}

@MainActor
final class MacCockpitViewModel: ObservableObject {
    @Published private(set) var state: NativeRuntimeState?
    @Published private(set) var uiSpec: JARVISUISpec?
    @Published private(set) var transcript = ""
    @Published private(set) var reply = ""
    @Published private(set) var transcriptEntries: [RedactedTranscriptEntry] = []
    @Published private(set) var auditEntries: [NativeAuditEntry] = []
    @Published private(set) var errorText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusLine = "Native runtime ready"
    @Published private(set) var voiceStatusLine = "Voice path unchecked"
    @Published private(set) var voiceStatusDetail = "JARVIS voice or silence; no system voice fallback."
    @Published private(set) var voiceAvailable = false

    private let voiceCapture = NativeVoiceCapture()
    private let runtime: NativeRuntimeBridge?
    private let runtimeStartupError: String?
    private let modelClient = NativeModelClient()
    private let transcriber = NativeTranscriptionClient()

    var isMounted: Bool { state?.mounted == true }

    var mountLine: String { isMounted ? "runtime mounted" : "runtime unmounted" }

    var pheromindVolatility: Double { state?.pheromind?.volatility ?? 0 }

    var swarmActivity: Double { state?.swarm?.activity ?? 0 }

    var cusumDriftScore: Double { state?.cusum?.driftScore ?? 0 }

    var identityContinuityOK: Bool { state?.identityContinuity?.ok == true }

    var identityContinuityLine: String { state?.identityContinuity?.indicator ?? "unknown" }

    func endocrineValue(_ key: String) -> Double { state?.endocrine[key] ?? 0 }

    var nativeConfigLine: String {
        "Model: \(modelClient.configuredModel) @ \(modelClient.configuredBaseURLText) | STT: \(transcriber.statusText) | Voice: \(voiceStatusLine)"
    }

    var runtimeForServices: NativeRuntimeBridge? {
        runtime
    }

    var modelClientForServices: NativeModelClient {
        modelClient
    }

    init() {
        do {
            runtime = try NativeRuntimeBridge()
            runtimeStartupError = nil
        } catch {
            runtime = nil
            runtimeStartupError = operatorMessage(.internalError)
            statusLine = "Native runtime unavailable"
            errorText = operatorMessage(.internalError)
            JARVISLog.error(subsystem: "runtime", event: "startup_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
        }
    }

    func refreshState() {
        do {
            let runtime = try requireRuntime()
            let snapshot = try runtime.state()
            let spec = try runtime.uiSpec()
            let voice = try runtime.voiceStatus()
            try validate(snapshot)
            try validate(spec)
            try validate(voice)
            state = snapshot
            uiSpec = spec
            refreshAudit()
            applyVoiceStatus(voice)
            statusLine = snapshot.mounted ? "Native runtime mounted" : "Native runtime unmounted"
            errorText = ""
        } catch {
            JARVISLog.error(subsystem: "runtime", event: "refresh_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            errorText = operatorMessage(.internalError)
            statusLine = "Native runtime error"
        }
    }

    func refreshAudit() {
        do {
            let runtime = try requireRuntime()
            let audit = try runtime.auditLog()
            auditEntries = audit.entries.reversed()
        } catch {
            JARVISLog.error(subsystem: "audit", event: "refresh_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            errorText = operatorMessage(.auditChainBroken)
        }
    }

    func toggleVoice() async {
        if voiceCapture.isRecording {
            await stopVoiceAndSend()
            return
        }
        do {
            try await voiceCapture.start()
            isRecording = true
            errorText = ""
            statusLine = "Listening"
        } catch {
            isRecording = false
            JARVISLog.error(subsystem: "voice", event: "start_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            errorText = operatorMessage(.voiceAnchorRejected)
        }
    }

    func send(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorText = "No command was provided."
            return
        }
        isBusy = true
        statusLine = "JARVIS is thinking"
        defer {
            isBusy = false
            refreshState()
        }
        do {
            let runtime = try requireRuntime()
            let prepared = try runtime.prepareTurn(clean)
            try validate(prepared.state)
            state = prepared.state
            let modelReply = try await modelClient.complete(messages: prepared.messages, requestedModel: prepared.model)
            let committed = try runtime.commitTurn(text: clean, reply: modelReply.text, model: modelReply.model)
            try validate(committed.state)
            let speech = try runtime.speechPolicy(for: committed.reply)
            try validate(speech)
            transcript = clean
            reply = committed.reply
            appendTranscript(role: "Operator", text: clean)
            appendTranscript(role: "JARVIS", text: committed.reply)
            JARVISLog.info(subsystem: "transcript", event: "turn_committed", fields: ["user_message": clean, "jarvis_message": committed.reply])
            state = committed.state
            applySpeechStatus(speech)
            statusLine = speech.spoken ? "JARVIS answered with native voice" : "JARVIS answered silently"
            errorText = ""
        } catch {
            JARVISLog.error(subsystem: "runtime", event: "send_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            errorText = operatorMessage(.internalError)
            statusLine = "Native runtime blocked"
        }
    }

    private func stopVoiceAndSend() async {
        do {
            let recording = try voiceCapture.stopAndCapture()
            isRecording = false
            isBusy = true
            statusLine = "Transcribing through native path"
            let text = try await transcriber.transcribe(recording)
            isBusy = false
            transcript = text
            await send(text)
        } catch {
            isBusy = false
            isRecording = false
            JARVISLog.error(subsystem: "voice", event: "capture_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            errorText = operatorMessage(.voiceAnchorRejected)
            statusLine = "Voice capture blocked"
        }
    }

    private func appendTranscript(role: String, text: String) {
        transcriptEntries.append(RedactedTranscriptEntry(role: role, text: text))
        if transcriptEntries.count > 20 {
            transcriptEntries.removeFirst(transcriptEntries.count - 20)
        }
    }

    private func requireRuntime() throws -> NativeRuntimeBridge {
        guard let runtime else {
            let reason = runtimeStartupError ?? "creation failed"
            throw NativeRuntimeError.runtime("Native runtime is unavailable: \(reason)")
        }
        return runtime
    }

    private func validate(_ snapshot: NativeRuntimeState) throws {
        guard snapshot.runtime == "native-swift-cpp" else {
            throw NativeRuntimeError.runtime("Blocked non-native runtime identity: \(snapshot.runtime)")
        }
        guard snapshot.pythonBetaPath == false else {
            throw NativeRuntimeError.runtime("Blocked runtime state that reports Python in the beta path.")
        }
        guard let voice = snapshot.voice else {
            throw NativeRuntimeError.runtime("Native runtime state omitted explicit voice policy.")
        }
        try validate(voice)
    }

    private func validate(_ voice: NativeVoiceStatus) throws {
        guard voice.runtime == "native-swift-cpp", voice.pythonBetaPath == false else {
            throw NativeRuntimeError.runtime("Blocked non-native voice status.")
        }
        guard voice.hardVoiceInvariant == "jarvis_voice_or_no_voice" else {
            throw NativeRuntimeError.runtime("Blocked unknown voice invariant: \(voice.hardVoiceInvariant)")
        }
        guard voice.spoken == false else {
            throw NativeRuntimeError.runtime("Blocked voice status that claimed spoken=true.")
        }
        guard voice.wrongVoiceFallbackAllowed == false,
              voice.systemVoiceFallbackAllowed == false,
              voice.nativeSystemVoiceAllowed == false,
              voice.pythonTTSAllowed == false,
              voice.fallbackPolicy == "none" else {
            throw NativeRuntimeError.runtime("Blocked voice policy with a fallback enabled.")
        }
        guard !backendLooksForbidden(voice.backend) else {
            throw NativeRuntimeError.runtime("Blocked forbidden voice backend: \(voice.backend)")
        }
    }

    private func validate(_ speech: NativeSpeechResponse) throws {
        if speech.spoken {
            let audio = speech.audioBase64 ?? ""
            let contentType = speech.contentType ?? ""
            guard speech.ok, !audio.isEmpty, contentType.hasPrefix("audio/") else {
                throw NativeRuntimeError.runtime("Blocked fake spoken=true without native audio.")
            }
        }
        let backend = speech.backend ?? speech.backendKind ?? ""
        guard !backendLooksForbidden(backend) else {
            throw NativeRuntimeError.runtime("Blocked forbidden speech backend: \(backend)")
        }
        guard speech.wrongVoiceFallbackAllowed != true,
              speech.systemVoiceFallbackAllowed != true,
              speech.nativeSystemVoiceAllowed != true,
              speech.pythonTTSAllowed != true else {
            throw NativeRuntimeError.runtime("Blocked speech response with fallback enabled.")
        }
        if let status = speech.status {
            try validate(status)
        }
    }

    private func validate(_ spec: JARVISUISpec) throws {
        try JARVISNativeUIRegistry.validate(spec)
    }

    private func applyVoiceStatus(_ voice: NativeVoiceStatus) {
        voiceAvailable = voice.available
        voiceStatusLine = voice.plainStatus
        voiceStatusDetail = voice.detail
    }

    private func applySpeechStatus(_ speech: NativeSpeechResponse) {
        if let status = speech.status {
            applyVoiceStatus(status)
        } else {
            voiceAvailable = speech.spoken
            voiceStatusLine = speech.statusLine
            voiceStatusDetail = speech.reason ?? "Speech response did not include a native voice status receipt."
        }
    }

    private func backendLooksForbidden(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("nsspeech") ||
            lower.contains("avspeech") ||
            lower.contains("speechsynthesis") ||
            lower.contains("system voice") ||
            lower.contains("tts_pocket") ||
            lower.contains("jarvis_bridge.py") ||
            lower.contains("python") ||
            lower == "say"
    }
}

struct RedactedTranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let redactedText: String

    init(role: String, text: String) {
        self.role = role
        self.redactedText = "<redacted:\(text.count)-chars digest:\(JARVISDialogDigest.digest(text))>"
    }
}

enum JARVISDialogDigest {
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct VoicePathStatusBlock: View {
    let title: String
    let detail: String
    let available: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: available ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(available ? GMRITheme.color.success : GMRITheme.color.danger)
            Text(detail)
                .font(.caption)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((available ? GMRITheme.color.success : GMRITheme.color.danger).opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NativeUISpecSurface: View {
    let spec: JARVISUISpec

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatePill(title: spec.schema, systemImage: "rectangle.3.group.fill", tint: GMRITheme.color.success)
                StatePill(title: spec.receipt, systemImage: "checkmark.seal.fill", tint: GMRITheme.color.success)
                Spacer()
            }
            Text("Policy: native renderer \(spec.rendererPolicy.nativeRenderer ? "on" : "off") | trusted HTML \(spec.rendererPolicy.trustedHTML ? "on" : "off") | trusted JS \(spec.rendererPolicy.trustedJavaScript ? "on" : "off")")
                .font(.caption)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.64))

            ForEach(spec.components) { component in
                NativeUIComponentRenderer(component: component, actionsByID: spec.actionsByID)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Enabled query receipts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GMRITheme.color.neutral)
                ForEach(spec.queries) { query in
                    NativeQueryRow(query: query)
                }
            }
        }
    }
}

private struct NativeUIComponentRenderer: View {
    let component: JARVISUIComponent
    let actionsByID: [String: JARVISUIActionDescriptor]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(component.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GMRITheme.color.neutral)
                    if let subtitle = component.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
                    }
                }
                Spacer()
                StatePill(title: component.kind.rawValue, systemImage: "square.grid.2x2.fill", tint: GMRITheme.color.success)
            }

            if let body = component.body {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.70))
                    .textSelection(.enabled)
            }

            switch component.kind {
            case .runtimeStatus:
                runtimeStatus
            case .metricCards:
                metricCards
            case .fieldSignalList:
                fieldSignals
            case .actionList:
                actionList
            }
        }
        .padding(14)
        .background(GMRITheme.color.neutral.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var runtimeStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(component.fields) { field in
                HStack {
                    Text(field.label)
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.58))
                    Spacer()
                    Text(field.value)
                        .foregroundStyle(GMRITheme.color.neutral)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }

    private var metricCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(component.metrics) { metric in
                GaugeCard(title: metric.label, value: metric.value, tint: GMRITheme.color.success)
            }
        }
    }

    private var fieldSignals: some View {
        VStack(alignment: .leading, spacing: 6) {
            if component.signals.isEmpty {
                Text("No live field signals.")
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
            } else {
                ForEach(Array(component.signals.prefix(5))) { signal in
                    HStack {
                        Text("\(signal.kind): \(signal.topic)")
                        Spacer()
                        Text(signal.strength, format: .number.precision(.fractionLength(3)))
                    }
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.78))
                }
            }
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(component.actionIDs, id: \.self) { actionID in
                if let action = actionsByID[actionID] {
                    NativeActionRow(action: action)
                } else {
                    Text("Unknown action descriptor: \(actionID)")
                        .font(.caption)
                        .foregroundStyle(GMRITheme.color.danger)
                }
            }
        }
    }
}

private struct NativeActionRow: View {
    let action: JARVISUIActionDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GMRITheme.color.neutral)
                Text(action.description)
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
                Text("HASP \(action.hasp.route) | audit \(action.hasp.auditEvent)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.48))
                if let reason = action.disabledReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(GMRITheme.color.danger)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatePill(title: action.risk.rawValue, systemImage: "shield.fill", tint: riskTint(action.risk))
                StatePill(title: action.status.rawValue, systemImage: action.enabled ? "checkmark.circle.fill" : "lock.fill", tint: action.enabled ? GMRITheme.color.success : GMRITheme.color.danger)
            }
        }
        .padding(10)
        .background(GMRITheme.color.background.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct NativeQueryRow: View {
    let query: JARVISUIQueryDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(query.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GMRITheme.color.neutral)
                Text("\(query.hasp.route) | audit \(query.hasp.auditEvent)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.50))
            }
            Spacer()
            StatePill(title: query.status.rawValue, systemImage: query.enabled ? "checkmark.circle.fill" : "lock.fill", tint: query.enabled ? GMRITheme.color.success : GMRITheme.color.danger)
        }
        .padding(10)
        .background(GMRITheme.color.neutral.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private func riskTint(_ risk: JARVISRiskClass) -> Color {
    switch risk {
    case .safe:
        return GMRITheme.color.success
    case .write:
        return GMRITheme.color.info
    case .sensitive:
        return GMRITheme.color.danger
    case .destructive:
        return GMRITheme.color.danger
    case .prohibited:
        return GMRITheme.color.info
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
                        colors: isThinking
                            ? [GMRITheme.color.success.opacity(0.95), GMRITheme.color.neutral.opacity(0.20), GMRITheme.color.background.opacity(0.10)]
                            : isListening
                                ? [GMRITheme.color.success.opacity(0.95), GMRITheme.color.success.opacity(0.55), GMRITheme.color.background.opacity(0.18)]
                                : [GMRITheme.color.success.opacity(0.88), GMRITheme.color.success.opacity(0.34), GMRITheme.color.background.opacity(0.24)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 160
                    )
                )
                .frame(width: 210, height: 210)
                .shadow(color: GMRITheme.color.success.opacity(isListening ? 0.85 : 0.45), radius: isListening ? 34 : 20)
            Circle()
                .stroke(GMRITheme.color.neutral.opacity(0.25), lineWidth: 1)
                .frame(width: 232, height: 232)
            Image(systemName: isThinking ? "sparkles" : (isListening ? "waveform" : "mic.fill"))
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(GMRITheme.color.neutral)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(GMRITheme.color.neutral.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(GMRITheme.color.neutral.opacity(0.16), lineWidth: 1)
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
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(GMRITheme.color.neutral)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct GaugeCard: View {
    let title: String
    let value: Double
    var tint: Color = GMRITheme.color.success

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(GMRITheme.color.neutral.opacity(0.10))
                    Capsule()
                        .fill(tint.opacity(0.78))
                        .frame(width: max(6, proxy.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 8)
            Text(value, format: .number.precision(.fractionLength(3)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(GMRITheme.color.neutral)
        }
        .padding(12)
        .background(GMRITheme.color.neutral.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatePill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct RecoveryBlock: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(GMRITheme.color.danger)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GMRITheme.color.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
    }
}
