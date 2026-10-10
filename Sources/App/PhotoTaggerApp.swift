import SwiftUI

@main
struct PhotoTaggerApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .task { await appModel.bootstrap() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}  // no document new-window churn
            CommandGroup(after: .toolbar) {
                Toggle("Show Debug Panel", isOn: Binding(
                    get: { appModel.showDebugPanel },
                    set: { appModel.showDebugPanel = $0 }
                ))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }}
