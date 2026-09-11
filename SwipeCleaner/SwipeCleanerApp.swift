import SwiftUI

@main
struct SwipeCleanerApp: App {
    @StateObject private var library = PhotoLibraryManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}

