// SessionStore.swift — placeholder, will be implemented in sdd-apply.
// Observable store that holds the current list of sessions and notifies
// SwiftUI views on change. Backed by StateFileWatcher + JSONLoader.
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionState] = []
    // TODO: wire watcher + loader in implementation phase
}
