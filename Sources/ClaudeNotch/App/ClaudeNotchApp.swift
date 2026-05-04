import SwiftUI

@main
struct ClaudeNotchApp: App {
    var body: some Scene {
        WindowGroup("Claude Notch") {
            SessionListView()
        }
        .windowResizability(.contentSize)
    }
}
