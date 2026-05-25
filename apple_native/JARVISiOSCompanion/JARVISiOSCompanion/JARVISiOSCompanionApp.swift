import SwiftUI

@main
struct JARVISiOSCompanionApp: App {
    @StateObject private var model = CompanionAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
                .onOpenURL { url in model.acceptPairingURL(url) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { @MainActor in
                model.handleScenePhase(newPhase)
            }
        }
    }
}
