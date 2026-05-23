import SwiftUI

@main
struct JARVISCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .preferredColorScheme(.dark)
                .tint(.green)
        }
    }
}
