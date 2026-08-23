import SwiftUI

@main
struct MKVSubtitleTranslatorApp: App {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environmentObject(updateController)
                .frame(minWidth: 980, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updateController.checkForUpdates() }
                    .disabled(!updateController.canCheckForUpdates)
            }
        }
    }
}
