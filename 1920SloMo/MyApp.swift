import SwiftUI

@main
struct ExtremeSloMoApp: App {
    @State private var isShowingStartupBackground = true

    var body: some Scene {
        WindowGroup {
            if isShowingStartupBackground {
                ResponsiveAppBackground()
                    .statusBarHidden()
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        isShowingStartupBackground = false
                    }
            } else {
                ContentView()
            }
        }
    }
}
