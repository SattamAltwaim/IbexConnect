import SwiftUI

@main
struct Ibex_connectApp: App {
    @State private var viewModel = AppViewModel()

    init() {
        // A dying ssh child must not take the app down with a broken pipe.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(viewModel)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // Tunnels and streams are closed; jobs keep running on the
                    // cluster and are re-adopted on next launch.
                    viewModel.onTerminate()
                }
        }
        .defaultSize(width: 960, height: 680)
    }
}
