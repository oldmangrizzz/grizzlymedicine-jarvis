import AppKit
import Darwin
import SwiftUI

private enum CockpitSignalHandlers {
    private static let termSource: DispatchSourceSignal = {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            if CutoverRecoveryCoordinator.checkpointIfActive(reason: "SIGTERM") {
                exit(EXIT_FAILURE)
            }
            exit(0)
        }
        source.resume()
        return source
    }()

    static func install() { _ = termSource }
}

final class CockpitAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CutoverRecoveryCoordinator.checkpointIfActive(reason: "Cmd-Q") {
            exit(EXIT_FAILURE)
        }
        return .terminateNow
    }
}

@main
struct JARVISMacCockpit: App {
    @NSApplicationDelegateAdaptor(CockpitAppDelegate.self) private var appDelegate
    @StateObject private var httpService = NativeRuntimeHTTPServiceController()
    @StateObject private var launchGate = JARVISLaunchGate()
    @StateObject private var bootGate = BootGateObserver()

    init() {
        if ProcessInfo.processInfo.environment["JARVIS_CUTOVER_FSM_SMOKE"] == "1" {
            exit(CutoverFSMSmoke.run())
        }
        if ProcessInfo.processInfo.environment["JARVIS_CUTOVER_SIGTERM_SMOKE"] == "1" {
            JARVISLog.configure()
            CockpitSignalHandlers.install()
            CutoverRecoveryCoordinator.enter(phase: .shadow, organ: "CharacterValues")
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["JARVIS_COCKPIT_SMOKE"] == "1" {
            let code: Int32
            do {
                do {
                    let runtime = try NativeRuntimeBridge()
                    let state = try runtime.state()
                    code = state.mounted && state.runtime == "native-swift-cpp" ? 0 : 2
                }
            } catch {
                code = 1
            }
            exit(code)
        }
        if ProcessInfo.processInfo.environment["JARVIS_COCKPIT_SPEAKER_SMOKE"] == "1" {
            do { try AuthorizedSpeakersSmoke.run(); exit(0) } catch { exit(1) }
        }
        CockpitSignalHandlers.install()
        JARVISLog.configure()
        JARVISLog.info(subsystem: "cockpit", event: "launch", fields: ["operator": "Robert Grizzly Hanson", "institution": "GMRI"])
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if launchGate.isBlocked {
                    SiriQuarantineRemediationView(warnings: launchGate.warnings)
                } else if !bootGate.isReady {
                    // V4R R10: BootView covers the 5.6-min cold-boot window with
                    // a flashy lifecycle surface. Transitions to MacCockpitView
                    // on phase=ready (the bootGate observer flips isReady).
                    BootView()
                        .environmentObject(httpService)
                        .task { httpService.start() }
                        .transition(.opacity)
                } else {
                    MacCockpitView()
                        .environmentObject(httpService)
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
            .task { launchGate.run() }
            .task { await bootGate.attach() }
            .animation(.easeInOut(duration: 0.6), value: bootGate.isReady)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class JARVISLaunchGate: ObservableObject {
    @Published private(set) var warnings: [SiriQuarantineWarning] = []

    var isBlocked: Bool {
        warnings.contains { $0.severity == .blocking }
    }

    func run() {
        guard warnings.isEmpty else { return }
        warnings = SiriQuarantineGuard.runChecks()
        if isBlocked {
            JARVISLog.fatal(subsystem: "security", event: "siri_quarantine_block", fields: ["warning_count": "\(warnings.count)"])
        } else {
            JARVISLog.info(subsystem: "security", event: "siri_quarantine_pass", fields: ["warning_count": "\(warnings.count)"])
        }
    }
}

// V4R R10 — BootGateObserver bridges the BootLifecycleTracker actor stream
// into a MainActor-published `isReady` flag so the cockpit's WindowGroup body
// can switch between BootView and MacCockpitView reactively.
@MainActor
final class BootGateObserver: ObservableObject {
    @Published private(set) var isReady: Bool = false
    private var streamTask: Task<Void, Never>?

    func attach() async {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await BootLifecycleTracker.shared.stream()
            for await snap in stream {
                await MainActor.run { self?.isReady = snap.isReady }
                if snap.isReady { break }
            }
        }
    }

    deinit { streamTask?.cancel() }
}

struct SiriQuarantineRemediationView: View {
    let warnings: [SiriQuarantineWarning]

    var body: some View {
        ZStack {
            GMRITheme.color.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Label("Siri quarantine block", systemImage: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(GMRITheme.color.warning)
                Text("JARVIS will not mount while Siri authorization is active for this app.")
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.82))
                ForEach(warnings, id: \.code) { warning in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(warning.code).font(.caption.weight(.bold)).foregroundStyle(GMRITheme.color.warning)
                        Text(warning.message).font(.callout).foregroundStyle(GMRITheme.color.neutral.opacity(0.72)).textSelection(.enabled)
                    }
                    .padding(12)
                    .background(GMRITheme.color.neutral.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("Remediation: revoke Siri/Speech authorization for JARVIS in System Settings, then relaunch.")
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
            }
            .padding(28)
            .frame(width: 620, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
