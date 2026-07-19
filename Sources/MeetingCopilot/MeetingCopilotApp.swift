import SwiftUI

@main
struct MeetingCopilotApp: App {
    @StateObject private var model = MeetingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 300)
        }
    }
}
