import SwiftUI

@main
struct JARVISWatchCompanionApp: App {
    @StateObject private var model = WatchCompanionModel()

    var body: some Scene {
        WindowGroup {
            WatchCompanionRootView()
                .environmentObject(model)
                .task {
                    model.activate()
                    await model.checkSiriWatchFaceMitigation()
                }
        }
    }
}
