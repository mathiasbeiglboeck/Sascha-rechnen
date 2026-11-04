import SwiftUI

@main
struct NotizbuchApp: App {
    @StateObject private var store: DocumentStore
    @StateObject private var sync: SyncEngine

    init() {
        let store = DocumentStore()
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncEngine(store: store))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(sync)
                // Papier ist weiß, Tinte soll nicht invertiert werden
                .preferredColorScheme(.light)
        }
    }
}
