import SwiftUI

struct ConnectionStatusBar: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)

                Text(connectionLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(vm.statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if vm.connection == .disconnected {
                Button("Reconnect") {
                    Task { await vm.connect() }
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Spacer()

            if let update = vm.availableUpdate {
                UpdateBadge(update: update)
            }

            let activeTunnels = vm.tunnelManager.tunnels.values.filter(\.isActive).count
            if activeTunnels > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("\(activeTunnels) tunnel\(activeTunnels == 1 ? "" : "s") open")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .help("SSH tunnels forwarding Jupyter to this Mac")
            }

            let activeJobs = vm.jobs.filter { !$0.isFinished }.count
            if activeJobs > 0 {
                Text("\(activeJobs) active job\(activeJobs == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var dotColor: Color {
        switch vm.connection {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .red
        }
    }

    private var connectionLabel: String {
        switch vm.connection {
        case .connected: "\(vm.username)@ibex"
        case .connecting: "connecting"
        case .disconnected: "offline"
        }
    }
}

/// "1.0.1 available · Download": the app can't install updates itself,
/// so this opens the release zip in the browser.
struct UpdateBadge: View {
    let update: AvailableUpdate

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: 5, height: 5)
            Text("IbexConnect \(update.version) available")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Link("Download", destination: update.downloadURL)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .help("A newer version is on GitHub. Download the zip and replace the app in your Applications folder.")
    }
}
