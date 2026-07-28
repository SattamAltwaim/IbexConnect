import SwiftUI
import AppKit

// MARK: - Display helpers shared by the job list and output panel

extension Job {
    var displayTitle: String {
        kind == .jupyter ? "Jupyter session" : name
    }

    var gpuLabel: String {
        let type: String
        switch gpuType {
        case "gpu", GPUInfo.anyType: type = "GPU"
        default: type = gpuType.replacingOccurrences(of: "_", with: " ").uppercased()
        }
        return gpuCount > 0 ? "\(type) ×\(gpuCount)" : type
    }

    var stateColor: Color {
        switch state {
        case .running: .green
        case .pending, .configuring: .orange
        case .completing: .teal
        case .completed: .blue
        case .failed, .cancelled, .timeout, .nodeFail, .outOfMemory: .red
        default: .secondary
        }
    }
}

// MARK: - One job row

struct JobRow: View {
    @Environment(AppViewModel.self) private var vm
    let job: Job
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var confirmingCancel = false

    /// "in about 3 hours" / "tomorrow at 02:26" — friendlier than a raw timestamp.
    static func relativeStart(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: job.kind == .jupyter ? "book.pages" : "terminal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(job.stateColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.displayTitle)
                        .font(.system(size: 14, weight: .semibold))

                    Text(job.gpuLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(job.state.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(job.stateColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(job.stateColor.opacity(0.1))
                        .clipShape(Capsule())
                }

                HStack(spacing: 12) {
                    Label(job.id, systemImage: "number")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    if let node = job.nodeName {
                        Label(node, systemImage: "server.rack")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if !job.elapsed.isEmpty, job.state == .running {
                        Label("\(job.elapsed) of \(job.timeLimit)", systemImage: "clock")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help("Time used so far, out of the job's time limit")
                    }
                }

                if job.state == .pending {
                    if let reason = job.pendingReason {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    if let start = job.estimatedStart {
                        Label(
                            "Slurm estimates it starts \(Self.relativeStart(start))",
                            systemImage: "calendar.badge.clock"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("An estimate from the scheduler — it usually starts sooner.")
                    }
                }

                if let tunnelError = job.tunnelError {
                    Text(tunnelError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 12)

            trailingControls

            if job.isFinished {
                Button {
                    Task { await vm.removeJob(job) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Remove this job from the list")
            } else {
                Button {
                    confirmingCancel = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Cancel this job on the cluster")
                .confirmationDialog(
                    "Cancel job \(job.id)?",
                    isPresented: $confirmingCancel
                ) {
                    Button("Cancel Job", role: .destructive) {
                        Task { await vm.cancelJob(job) }
                    }
                    Button("Keep Running", role: .cancel) {}
                } message: {
                    Text("The job will be stopped on the cluster. This can't be undone.")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.08)
                : (isHovered ? Color.primary.opacity(0.02) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // MARK: Right side: Jupyter link / progress

    @ViewBuilder
    private var trailingControls: some View {
        if job.kind == .jupyter {
            if let link = job.jupyterLink {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("localhost:\(job.localPort.map(String.init) ?? "")")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                    HStack(spacing: 6) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            vm.statusMessage = "Link copied — in VS Code, run “Jupyter: Specify Jupyter Server for Connections” and paste it"
                        } label: {
                            Text("Copy Link")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .help("Copy the full link (with its access token) — paste it into a browser or into VS Code's “Jupyter: Specify Jupyter Server for Connections”")

                        Button {
                            if let url = URL(string: link) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Open")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open Jupyter in your browser")
                    }
                }
            } else if job.state == .running {
                if job.tunnelError != nil {
                    Button {
                        vm.ensureJupyterConnection(job)
                    } label: {
                        Text("Retry Connection")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if !job.tunnelActive && !job.jupyterSetupStarted {
                    Button {
                        vm.ensureJupyterConnection(job)
                    } label: {
                        Text("Connect")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help("Open the tunnel and get the notebook link")
                } else {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(job.setupStage ?? "Preparing link…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .help("Waiting for Jupyter to start on the compute node")
                }
            } else if job.isFinished {
                // A session that ended without ever producing a link would
                // otherwise render nothing at all, which reads as a hang.
                Text("Session ended")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help("The job is no longer running. Select it to read its output.")
            }
        }
    }
}
