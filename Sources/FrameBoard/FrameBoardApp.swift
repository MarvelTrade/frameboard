import SwiftUI

@main
struct FrameBoardApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(state)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1300, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть видео…") { state.openFilePanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
