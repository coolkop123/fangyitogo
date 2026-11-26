import SwiftUI

@main
struct EarTranslateApp: App {
    @StateObject private var interpreter = Interpreter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(interpreter)
        }
    }
}
