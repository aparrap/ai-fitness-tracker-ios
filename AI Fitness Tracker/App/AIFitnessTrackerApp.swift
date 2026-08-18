import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AutomaticHealthSyncCoordinator.shared.registerObserver()
        return true
    }
}

@main
struct AIFitnessTrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            SyncView()
                .task {
                    await AutomaticHealthSyncCoordinator.shared.activate()
                }
        }
    }
}
