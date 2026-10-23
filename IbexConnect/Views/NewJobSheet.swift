import SwiftUI

struct NewJobSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var kind: JobKind = .jupyter
    @State private var selectedGPU = ""
    @State private var gpuCount = 1
    @State private var hours = 4
    @State private var memoryGB = 32
    @State private var cpus = 8
    @State private var jobName = ""
    @State private var command = ""
    @State private var isSubmitting = false
    @State private var submitError: String?

    /// "Any GPU" first, then each specific model.
    private var gpuOptions: [GPUInfo] {
        guard let any = GPUInfo.anyOption(from: vm.gpuList) else { return [] }
        return [any] + vm.gpuList
    }

    private var selectedGPUInfo: GPUInfo? {
        gpuOptions.first { $0.type == selectedGPU }
    }

    private var maxCount: Int {
        max(selectedGPUInfo?.maxPerNode ?? 1, 1)
    }

    /// What actually moves the start time on this cluster is the GPU count and
    /// whether a model is pinned — not the time limit.
    private var schedulingTip: String {
        if gpuCount >= 4 {
            return "Asking for 4 or more GPUs on one node sends this to the smaller wide-node queues, "
                + "where waits are measured in days. The time limit makes little difference — the GPU count does."
        }
        return "The GPU count and the model you pin drive the wait far more than the time limit."
    }

    /// A job's GPUs must all come from one node, so the largest free block on a
    /// single node — not the cluster-wide total — decides whether it starts now.
    private var availabilityWarning: String? {
        guard let info = selectedGPUInfo else { return nil }
        if info.free == 0 {
            return "Every \(info.displayName) GPU is busy right now — this job will wait in the queue."
        }
        if gpuCount > info.largestFreeBlock {
            var message = "No single node has \(gpuCount) free "
                + (info.isAny ? "GPUs" : "\(info.displayName) GPUs")
                + " right now (the best is \(info.largestFreeBlock)). This job will queue, possibly for days. "
                + "Asking for \(info.largestFreeBlock) or fewer would start much sooner."
            if !info.isAny {
                message += " So would switching to “Any GPU”."
            }
            return message
        }
        return nil
    }

    private var canSubmit: Bool {
        guard !selectedGPU.isEmpty, !isSubmitting else { return false }
        if kind == .batch {
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("New Job")
                    .font(.system(size: 22, weight: .bold))
                Text(
                    kind == .jupyter
                        ? "Starts Jupyter on a GPU node and gives you a link for your browser or VS Code."
                        : "Runs your commands on a GPU node. Watch the output live in the app."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Picker("", selection: $kind) {
                Text("Jupyter Notebook").tag(JobKind.jupyter)
                Text("Batch Command").tag(JobKind.batch)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    gpuSection

                    if !selectedGPU.isEmpty {
                        countSection
                    }

                    HStack(spacing: 16) {
                        ConfigField(
                            label: "HOURS",
                            value: $hours,
                            range: 1...336,
                            help: "How long the job may run before Slurm stops it"
                        )
                        ConfigField(
                            label: "MEMORY (GB)",
                            value: $memoryGB,
                            range: 8...512,
                            help: "System RAM for the job, not GPU memory"
                        )
                        ConfigField(
                            label: "CPU CORES",
                            value: $cpus,
                            range: 1...64,
                            help: "CPU cores for data loading and preprocessing"
                        )
                    }

                    Text(schedulingTip)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if kind == .batch {
                        batchSection
                    }
                }
                .padding(1)
            }

            if let submitError {
                Text(submitError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    submit()
                } label: {
                    Text(kind == .jupyter ? "Start Session" : "Submit Job")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(canSubmit ? Color.primary : Color.primary.opacity(0.3))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: kind == .batch ? 640 : 520)
        .onAppear {
            // Default to no model pin — it is nearly always the fastest start.
            selectedGPU = gpuOptions.first?.type ?? ""
        }
    }

    // MARK: - Sections

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("GPU TYPE")

            if vm.gpuList.isEmpty {
                Text("Still loading GPU availability — hold on a moment.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(gpuOptions) { gpu in
                        GPUOption(gpu: gpu, isSelected: selectedGPU == gpu.type) {
                            selectedGPU = gpu.type
                            gpuCount = min(gpuCount, max(gpu.maxPerNode, 1))
                        }
                    }
                }

                if selectedGPUInfo?.isAny == false {
                    Text("Pinning a model can add days to the queue. “Any GPU” starts soonest.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if let warning = availabilityWarning {
                    Label(warning, systemImage: "hourglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var countSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NUMBER OF GPUS")

            HStack(spacing: 8) {
                ForEach(1...maxCount, id: \.self) { n in
                    let startsNow = n <= (selectedGPUInfo?.largestFreeBlock ?? 0)
                    Button {
                        gpuCount = n
                    } label: {
                        Text("\(n)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .frame(width: 32, height: 28)
                            .background(gpuCount == n ? Color.primary : Color.primary.opacity(0.04))
                            .foregroundStyle(gpuCount == n ? Color(nsColor: .windowBackgroundColor) : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                            .overlay(alignment: .topTrailing) {
                                if startsNow {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 5, height: 5)
                                        .offset(x: 2, y: -2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(startsNow
                        ? "\(n) available now on a single node"
                        : "No node has \(n) free right now — this would queue")
                }

                if let info = selectedGPUInfo {
                    Text(info.largestFreeBlock > 0
                        ? "green = starts now (up to \(info.largestFreeBlock))"
                        : "none free now")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            }
        }
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("JOB NAME")
                TextField("", text: $jobName, prompt: Text("e.g. train-resnet"))
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("COMMANDS TO RUN")

                TextEditor(text: $command)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if command.isEmpty {
                            Text("module load python/3.11.0\npython train.py --epochs 10")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                Text("Runs as a bash script from your home directory on the node. `module load …` works here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(1)
    }

    // MARK: - Submit

    private func submit() {
        isSubmitting = true
        submitError = nil
        let config = JobConfig(
            kind: kind,
            name: kind == .jupyter ? "jupyter" : (jobName.isEmpty ? "job" : jobName),
            gpuType: selectedGPU,
            gpuCount: gpuCount,
            hours: hours,
            memoryGB: memoryGB,
            cpus: cpus,
            command: command,
            token: JobConfig.newToken()
        )
        Task {
            do {
                try await vm.submitJob(config: config)
                dismiss()
            } catch {
                submitError = "Submission failed: \((error as? IbexError)?.localizedDescription ?? error.localizedDescription)"
            }
            isSubmitting = false
        }
    }
}

// MARK: - Components

struct GPUOption: View {
    let gpu: GPUInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(gpu.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(gpu.free) free")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(subtitleColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.primary : Color.primary.opacity(0.04))
            .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(gpu.free > 0 || isSelected ? 1 : 0.55)
        .help(helpText)
    }

    private var subtitleColor: Color {
        if isSelected {
            return Color(nsColor: .windowBackgroundColor).opacity(0.8)
        }
        return gpu.free > 0 ? Color.secondary : Color(nsColor: .tertiaryLabelColor)
    }

    private var helpText: String {
        gpu.free > 0
            ? "\(gpu.free) of \(gpu.total) free now"
            : "None free right now — a job would wait in the queue"
    }
}


struct ConfigField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            HStack(spacing: 0) {
                TextField("", value: $value, format: .number)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(width: 40)
                    .onSubmit { clamp() }

                Stepper("", value: $value, in: range)
                    .labelsHidden()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .help(help)
        .onChange(of: value) { clamp() }
    }

    private func clamp() {
        if value < range.lowerBound { value = range.lowerBound }
        if value > range.upperBound { value = range.upperBound }
    }
}
