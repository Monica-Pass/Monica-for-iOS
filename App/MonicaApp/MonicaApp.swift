import SwiftUI

@main
struct MonicaApp: App {
    private let environment = MonicaAppEnvironment()

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment)
        }
    }
}
