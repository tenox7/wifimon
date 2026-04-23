import SwiftUI

@main
struct WifiMonApp: App {
    var body: some Scene {
        WindowGroup("WifiMon") {
            ContentView()
        }
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentSize)
    }
}
