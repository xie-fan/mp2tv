import SwiftUI

@main
struct Mp2tvApp: App {
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
    }
}
