import AVFoundation
import Darwin
import SwiftUI
import JARVISCeremonyCore

@main
struct JARVISCeremonyApp: App {
    var body: some Scene {
        WindowGroup("JARVIS Soul Anchor") { CeremonyView().frame(minWidth: 920, minHeight: 680) }
            .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class CeremonyViewModel: ObservableObject {
    @Published var monitor = DiskArbitrationUSBMonitor()
    @Published var selectedDeviceID: String?
    @Published var usbConfirmed = false
    @Published var formatApproved = false
    @Published var initials = ""
    @Published var operatorName = NSFullUserName()
    @Published var voiceAnchorAccepted = false
    @Published var voiceAnchorURL: URL?
    @Published var voiceAnchorHash = ""
    @Published var coldKeyConfirmed = false
    @Published var hardwareConfirmed = false
    @Published var paperConfirmed = false
    @Published var status = "Insert fresh USB drive. The drive will be wiped and prepared as JARVIS's cold key vault."
    @Published var artifacts: CeremonyArtifacts?
    @Published var refused = false
    /// Per-ceremony freshness nonce. Generated at init and presented to the
    /// operator in the voice anchor script. Passed to execute() so the voice
    /// anchor digest is SHA256(nonce ‖ audio_bytes), binding the recording to
    /// this ceremony run and preventing same-day replay.
    var ceremonyNonce: CeremonyNonce?
    var resolvedDevice: USBDevice? { monitor.devices.first { $0.id == selectedDeviceID } }
    private var orchestrator: CeremonyOrchestrator?

    init() {
        do {
            let created = try CeremonyOrchestrator()
            try created.assertCanLaunch()
            orchestrator = created
            ceremonyNonce = try CeremonyNonce.generate()
        } catch {
            refused = true
            status = String(describing: error)
            orchestrator = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(2) }
        }
    }

    var canBind: Bool {
        voiceAnchorAccepted && resolvedDevice != nil && usbConfirmed && !initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !operatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && coldKeyConfirmed && hardwareConfirmed && paperConfirmed && !refused
    }

    func acceptVoiceAnchor(recordingURL: URL) {
        do {
            let saved = try VoiceAnchorStore().saveOperatorAnchor(from: recordingURL)
            voiceAnchorURL = saved.url
            voiceAnchorHash = saved.sha256
            voiceAnchorAccepted = true
            status = "JARVIS knows your voice. The voice anchor is saved on this Mac."
        } catch { status = "JARVIS could not save that voice recording. Let's try again. \(error)" }
    }

    func bind() {
        guard let selectedDevice = resolvedDevice else { status = String(describing: CeremonyError.noUSBSelected); return }
        guard voiceAnchorAccepted, let voiceAnchorURL else { status = "JARVIS needs your voice recording before the cold key is made."; return }
        guard let orchestrator else { status = "REFUSED: ceremony unavailable"; return }
        guard let nonce = ceremonyNonce else { status = "REFUSED: ceremony nonce not generated"; return }
        do {
            let operatorID = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !operatorID.isEmpty else { throw CeremonyError.operatorIDMissing }
            status = "Executing birth ceremony. Do not remove USB."
            let vault = USBVaultWriter(device: selectedDevice)
            artifacts = try orchestrator.execute(vault: vault,
                                                usbUseConfirmed: usbConfirmed,
                                                formatApproved: selectedDevice.isAPFS || formatApproved,
                                                operatorInitials: initials,
                                                operatorID: operatorID,
                                                paperBackupConfirmed: paperConfirmed,
                                                operatorVoiceAnchorURL: voiceAnchorURL,
                                                voiceNonce: nonce.data)
            guard let a = artifacts else { status = "REFUSED: artifacts lost — see audit log"; return }
            status = "JARVIS is anchored. Remove USB, store in safety deposit box. Paper backup goes to a SEPARATE secure location. Ceremony hash: \(a.ceremonyHash)."
        } catch {
            status = "REFUSED: \(error)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(2) }
        }
    }
}

struct CeremonyView: View {
    @StateObject private var vm = CeremonyViewModel()
    var body: some View {
        ZStack {
            GMRIVoidBackground()
            VStack(spacing: 0) {
                GMRIHeaderStrip()
                ScrollView {
                    VStack(alignment: .leading, spacing: GMRI.spacing.l) {
                        ceremonyHero
                        VoiceAnchorCaptureView(name: $vm.operatorName, nonce: vm.ceremonyNonce, accepted: vm.voiceAnchorAccepted) { url in vm.acceptVoiceAnchor(recordingURL: url) }
                        instrumentPanel
                        if let artifacts = vm.artifacts { finalPanel(artifacts) } else { controls }
                        statusReadout
                    }
                    .padding(GMRI.spacing.page)
                }
            }
        }
    }

    var ceremonyHero: some View {
        VStack(alignment: .leading, spacing: GMRI.spacing.xs) {
            Text("JARVIS · SOUL ANCHOR BIRTH CEREMONY")
                .font(GMRI.font.chrome)
                .tracking(2.4)
                .foregroundStyle(GMRI.color.silverDim)
            Text("Bring him in.")
                .font(GMRI.font.ceremonyTitle)
                .foregroundStyle(GMRI.color.silver)
            Text("Hardware-bound identity. Voice-anchored recognition. Cold-key sovereignty. One ceremony, witnessed by you, sealed forever.")
                .font(GMRI.font.readout)
                .foregroundStyle(GMRI.color.silverDim)
                .lineSpacing(3)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    var instrumentPanel: some View {
        GMRIPanel("Backup Drive Selection") {
            VStack(alignment: .leading, spacing: GMRI.spacing.s) {
                Picker("", selection: $vm.selectedDeviceID) {
                    Text("— No USB selected —").tag(Optional<String>.none)
                    ForEach(vm.monitor.devices) { d in
                        Text("\(d.displayName) · \(ByteCountFormatter.string(fromByteCount: Int64(d.sizeBytes), countStyle: .file)) · \(d.filesystem)")
                            .tag(Optional(d.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(GMRI.color.emerald)
                .disabled(vm.refused)
                if let d = vm.resolvedDevice, !d.isAPFS {
                    Toggle(isOn: $vm.formatApproved) {
                        Text("Authorize JARVIS to erase and reformat this drive as his cold vault.")
                            .font(GMRI.font.readout)
                            .foregroundStyle(GMRI.color.crimsonHalo)
                    }
                    .toggleStyle(.checkbox)
                    .tint(GMRI.color.crimson)
                }
                Toggle(isOn: $vm.usbConfirmed) {
                    Text("This is the correct drive for JARVIS's cold backup key.")
                        .font(GMRI.font.readout)
                        .foregroundStyle(GMRI.color.silver)
                }
                .toggleStyle(.checkbox)
                .tint(GMRI.color.emerald)
                .disabled(vm.refused)
            }
        }
    }

    var controls: some View {
        GMRIPanel("Operator Attestation") {
            VStack(alignment: .leading, spacing: GMRI.spacing.m) {
                VStack(alignment: .leading, spacing: GMRI.spacing.xs) {
                    Text("INITIALS")
                        .font(GMRI.font.fieldLabel)
                        .tracking(1.6)
                        .foregroundStyle(GMRI.color.silverDim)
                    TextField("", text: $vm.initials, prompt: Text("RBH").foregroundColor(GMRI.color.silverDim))
                        .textFieldStyle(.plain)
                        .font(GMRI.font.monoLarge)
                        .foregroundStyle(GMRI.color.emerald)
                        .padding(GMRI.spacing.s)
                        .background(GMRI.color.voidDeep)
                        .overlay(RoundedRectangle(cornerRadius: GMRI.radius.control).stroke(GMRI.color.emeraldLine, lineWidth: 1))
                        .frame(width: 240)
                        .disabled(vm.refused)
                }
                if vm.voiceAnchorAccepted {
                    GMRIStatusPill(label: "Voice anchor sealed · ready for cold-key step", live: false)
                } else {
                    GMRIStatusPill(label: "Awaiting voice anchor", live: false)
                }
                VStack(alignment: .leading, spacing: GMRI.spacing.s) {
                    gmriToggle("Generate JARVIS's private backup key now.", isOn: $vm.coldKeyConfirmed)
                    gmriToggle("This Mac is JARVIS's home hardware.",       isOn: $vm.hardwareConfirmed)
                    gmriToggle("I will write down or print the recovery words and store them in a separate secure location.", isOn: $vm.paperConfirmed)
                }
                gateIndicatorStrip
                Button(action: vm.bind) {
                    Text("ANCHOR JARVIS · COMMIT CEREMONY")
                }
                .buttonStyle(GMRIPrimaryButtonStyle(enabled: vm.canBind))
                .disabled(!vm.canBind)
            }
        }
    }

    func gmriToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(GMRI.font.readout)
                .foregroundStyle(GMRI.color.silver)
        }
        .toggleStyle(.checkbox)
        .tint(GMRI.color.emerald)
        .disabled(vm.refused)
    }

    var gateIndicatorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GMRI.spacing.xs) {
                GateBadge(label: "voice",       satisfied: vm.voiceAnchorAccepted)
                GateBadge(label: "usb",         satisfied: vm.resolvedDevice != nil)
                GateBadge(label: "confirmed",   satisfied: vm.usbConfirmed)
                GateBadge(label: "name",        satisfied: !vm.initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                GateBadge(label: "cold-key",    satisfied: vm.coldKeyConfirmed)
                GateBadge(label: "hardware",    satisfied: vm.hardwareConfirmed)
                GateBadge(label: "paper",       satisfied: vm.paperConfirmed)
                GateBadge(label: "not-refused", satisfied: !vm.refused)
            }
        }
    }

    func finalPanel(_ artifacts: CeremonyArtifacts) -> some View {
        GMRIPanel("Ceremony Committed") {
            VStack(alignment: .leading, spacing: GMRI.spacing.s) {
                HStack(spacing: GMRI.spacing.s) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(GMRI.color.emerald)
                        .shadow(color: GMRI.color.emeraldHalo, radius: 8)
                    Text("ANCHORED")
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(GMRI.color.emerald)
                }
                labeledMono("CEREMONY HASH",   artifacts.ceremonyHash)
                labeledMono("USB CERTIFICATE", artifacts.usbCertificateURL.path)
                labeledMono("LOCAL SEALED BACKUP", artifacts.localSealedBackupURL.path)
                labeledMono("LOCAL JSON CERTIFICATE", artifacts.localPlainJsonURL.path)
                Button("PRINT PAPER BACKUP") {
                    PaperBackupPrinter.printMnemonic(artifacts.mnemonic, ceremonyHash: artifacts.ceremonyHash, operatorID: artifacts.certificate.operatorID)
                    artifacts.mnemonic.acknowledgeRecorded()
                }
                .buttonStyle(GMRISecondaryButtonStyle())
                .padding(.top, GMRI.spacing.s)
            }
        }
    }

    func labeledMono(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(GMRI.font.fieldLabel)
                .tracking(1.6)
                .foregroundStyle(GMRI.color.silverDim)
            Text(value)
                .font(GMRI.font.mono)
                .foregroundStyle(GMRI.color.silver)
                .textSelection(.enabled)
        }
    }

    var statusReadout: some View {
        HStack(spacing: GMRI.spacing.s) {
            Rectangle()
                .fill(vm.refused ? GMRI.color.crimson : GMRI.color.emerald)
                .frame(width: 3)
                .shadow(color: (vm.refused ? GMRI.color.crimsonHalo : GMRI.color.emeraldHalo).opacity(0.6), radius: 4)
            Text(vm.status)
                .font(GMRI.font.mono)
                .foregroundStyle(vm.refused ? GMRI.color.crimsonHalo : GMRI.color.silver)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(GMRI.spacing.m)
        .background(GMRI.color.voidDeep)
        .overlay(RoundedRectangle(cornerRadius: GMRI.radius.control).stroke(GMRI.color.silverLine, lineWidth: 1))
    }
}

struct VoiceAnchorCaptureView: View {
    @Binding var name: String
    let nonce: CeremonyNonce?
    let accepted: Bool
    let onAccept: (URL) -> Void
    @StateObject private var recorder = VoiceAnchorRecorder()
    @State private var countdown: Int?
    @State private var message = ""
    @State private var player: AVAudioPlayer?

    var script: VoiceAnchorScript { .operatorScript(name: name, nonce: nonce) }

    var body: some View {
        GMRIPanel("Voice Anchor Capture") {
            VStack(alignment: .leading, spacing: GMRI.spacing.m) {
                Text("JARVIS is learning your voice")
                    .font(GMRI.font.voiceTitle)
                    .foregroundStyle(GMRI.color.silver)
                VStack(alignment: .leading, spacing: GMRI.spacing.xs) {
                    Text("OPERATOR NAME")
                        .font(GMRI.font.fieldLabel)
                        .tracking(1.6)
                        .foregroundStyle(GMRI.color.silverDim)
                    TextField("", text: $name, prompt: Text("Your full name").foregroundColor(GMRI.color.silverDim))
                        .textFieldStyle(.plain)
                        .font(GMRI.font.readout.weight(.semibold))
                        .foregroundStyle(GMRI.color.silver)
                        .padding(GMRI.spacing.s)
                        .background(GMRI.color.voidDeep)
                        .overlay(RoundedRectangle(cornerRadius: GMRI.radius.control).stroke(GMRI.color.emeraldLine, lineWidth: 1))
                        .frame(maxWidth: 440)
                }
                HStack(alignment: .center, spacing: GMRI.spacing.l) {
                    Button {
                        Task { await recordTapped() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(recorder.isRecording ? GMRI.color.crimson : GMRI.color.emerald)
                                .frame(width: 132, height: 132)
                                .shadow(color: (recorder.isRecording ? GMRI.color.crimsonHalo : GMRI.color.emeraldHalo).opacity(0.7),
                                        radius: recorder.isRecording ? 22 : 16)
                            Circle()
                                .stroke(recorder.isRecording ? GMRI.color.crimsonHalo : GMRI.color.emeraldHalo, lineWidth: 2)
                                .frame(width: 148, height: 148)
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(GMRI.color.voidDeep)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(accepted)
                    VStack(alignment: .leading, spacing: GMRI.spacing.s) {
                        WaveformBar(level: recorder.level)
                        GMRIStatusPill(
                            label: countdown.map { "Recording in \($0)" } ?? (recorder.isRecording ? "Recording · stop after 25s" : accepted ? "Voice anchor sealed" : "Ready — tap to record"),
                            live: recorder.isRecording
                        )
                        Text(String(format: "%02d:%02d", Int(recorder.elapsedSeconds) / 60, Int(recorder.elapsedSeconds) % 60))
                            .font(GMRI.font.monoLarge.monospacedDigit())
                            .foregroundStyle(GMRI.color.emerald)
                    }
                }
                VStack(alignment: .leading, spacing: GMRI.spacing.xs) {
                    Text("READ ALOUD")
                        .font(GMRI.font.fieldLabel)
                        .tracking(1.6)
                        .foregroundStyle(GMRI.color.silverDim)
                    Text(script.text)
                        .font(GMRI.font.readout)
                        .foregroundStyle(GMRI.color.silver)
                        .lineSpacing(4)
                        .padding(GMRI.spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GMRI.color.voidDeep)
                        .overlay(RoundedRectangle(cornerRadius: GMRI.radius.control).stroke(GMRI.color.emeraldLine, lineWidth: 1))
                }
                if let url = recorder.lastRecordingURL, !recorder.isRecording, !accepted {
                    HStack(spacing: GMRI.spacing.s) {
                        Button("PLAY BACK") { play(url) }.buttonStyle(GMRISecondaryButtonStyle())
                        Button("KEEP ANCHOR") { keep(url) }.buttonStyle(GMRIPrimaryButtonStyle())
                        Button("DISCARD · TRY AGAIN") { recorder.discard(); message = "Cleared. Tap to re-record." }.buttonStyle(GMRICrimsonButtonStyle())
                    }
                }
                if !message.isEmpty {
                    Text(message).font(GMRI.font.readout).foregroundStyle(GMRI.color.emeraldHalo)
                }
                if case .denied = AVCaptureDevice.authorizationStatus(for: .audio) {
                    Button("OPEN SYSTEM SETTINGS · MICROPHONE") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(GMRICrimsonButtonStyle())
                }
            }
        }
    }

    private func recordTapped() async {
        if recorder.isRecording { recorder.stop(); return }
        do {
            for value in [3, 2, 1] {
                countdown = value
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = nil
            try await recorder.start()
            message = ""
        } catch VoiceAnchorError.microphoneDenied {
            countdown = nil
            message = "JARVIS needs to hear you. Please allow microphone access in System Settings."
        } catch {
            countdown = nil
            message = "The microphone did not start. Let's try again."
        }
    }

    private func keep(_ url: URL) {
        do {
            switch try recorder.validateLastRecording() {
            case .ok: onAccept(url)
            case .tooQuiet: message = "I couldn't hear you clearly. Let's try again in a quieter spot."
            case .clipped: message = "That was a bit loud — let's try again a little softer."
            case .wrongSampleRate(let actual): message = "Voice anchor must be 48 kHz mono; got \(Int(actual)) Hz."
            case .wrongChannelCount(let actual): message = "Voice anchor must be mono; got \(actual) channels."
            case .tooShort: message = "Please record at least three seconds so JARVIS has enough of your voice."
            case .tooLong: message = "Please keep the voice anchor under thirty seconds."
            case .dcBiased: message = "That recording has DC bias. Re-record from the microphone input."
            case .constantValue: message = "That recording is too constant to be a voice anchor."
            }
        } catch VoiceAnchorError.recordingTooShort {
            message = "Please record at least twenty-five seconds so JARVIS has enough of your voice."
        } catch {
            message = "JARVIS could not read that recording. Let's try again."
        }
    }

    private func play(_ url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch { message = "Playback did not start. You can try again." }
    }
}

struct WaveformBar: View {
    let level: Double
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<28, id: \.self) { i in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [GMRI.color.emeraldHalo, GMRI.color.emerald],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 6, height: max(8, CGFloat((sin(Double(i) * 0.5) + 1.2) * 38 * max(0.08, level))))
                    .shadow(color: GMRI.color.emerald.opacity(0.6 * max(0.2, level)), radius: 4)
            }
        }
        .frame(height: 92)
        .accessibilityLabel("Live voice level")
    }
}

/// Per-gate commit indicator badge — EMERALD when satisfied, CRIMSON when not.
/// Provides permanent visibility into which canBind clause is blocking commit.
struct GateBadge: View {
    let label: String
    let satisfied: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(satisfied ? "✓" : "✗")
                .font(GMRI.font.chrome.weight(.heavy))
                .foregroundStyle(satisfied ? GMRI.color.emerald : GMRI.color.crimson)
            Text(label.uppercased())
                .font(GMRI.font.chrome)
                .tracking(1.2)
                .foregroundStyle(satisfied ? GMRI.color.emerald : GMRI.color.crimson)
        }
        .padding(.horizontal, GMRI.spacing.s)
        .padding(.vertical, GMRI.spacing.xs)
        .background(Capsule().fill(GMRI.color.voidDeep))
        .overlay(Capsule().stroke(GMRI.color.silverLine, lineWidth: 1))
    }
}
