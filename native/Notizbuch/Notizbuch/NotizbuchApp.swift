import SwiftUI

@main
struct NotizbuchApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                // Papier ist weiß, Tinte soll nicht invertiert werden
                .preferredColorScheme(.light)
        }
    }
}
