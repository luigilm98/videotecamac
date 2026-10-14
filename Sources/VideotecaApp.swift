import SwiftUI

@main
struct VideotecaApp: App {
    @StateObject private var model = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 720)
                .task {
                    model.startInitialScanIfNeeded()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Apri film selezionato") {
                    NotificationCenter.default.post(name: .openSelectedMovie, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}

extension Notification.Name {
    static let openSelectedMovie = Notification.Name("VideotecaOpenSelectedMovie")
}
