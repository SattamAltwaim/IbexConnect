import SwiftUI

struct JobListView: View {
    @Environment(AppViewModel.self) private var vm
    let onSelectJob: (Job) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("MY JOBS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(1)

                if !vm.jobs.isEmpty {
                    Text("— click a job to watch its output")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            }

            if vm.jobs.isEmpty {
                VStack(spacing: 6) {
                    Text(vm.connection == .connected ? "No jobs yet" : "Not connected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    if vm.connection == .connected {
                        Text("Press ⌘N to start a Jupyter session or submit a batch job")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.jobs) { job in
                        JobRow(
                            job: job,
                            isSelected: vm.selectedJobID == job.id,
                            onSelect: { onSelectJob(job) }
                        )
                        if job.id != vm.jobs.last?.id {
                            Divider()
                                .padding(.horizontal, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
