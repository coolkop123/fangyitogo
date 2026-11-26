import SwiftUI

@main
struct EarTranslateApp: App {
    @StateObject private var interpreter = Interpreter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(interpreter)
        }
    }
}
