// ClaudeNotchApp.swift
// SwiftUI entry point. We host an AppKit AppController via NSApplicationDelegateAdaptor
// because the actual UI lives in an NSPanel (not a SwiftUI Window/Scene).
// `Settings { EmptyView() }` is the trick to keep the SwiftUI App protocol happy
// without creating an actual main window.
import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var controller

    var body: some Scene {
        Settings { EmptyView() }
    }
}
