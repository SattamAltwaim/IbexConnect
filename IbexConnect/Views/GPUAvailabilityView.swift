import SwiftUI

struct GPUAvailabilityView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("GPU AVAILABILITY")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(1)

                if vm.isLoadingGPUs {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if vm.gpuList.isEmpty && !vm.isLoadingGPUs {
                Text(
                    vm.connection == .connected
                        ? "No GPU information reported by the cluster."
                        : "GPU availability appears here once connected."
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(vm.gpuList) { gpu in
                        GPUCard(gpu: gpu)
                    }
                }
            }
        }
    }
}

struct GPUCard: View {
    let gpu: GPUInfo
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(gpu.displayName)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(gpu.free)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(gpu.free > 0 ? Color.primary : Color.primary.opacity(0.3))
                    .contentTransition(.numericText())
                Text("of \(gpu.total) free")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help("\(gpu.free) of \(gpu.total) \(gpu.displayName) GPUs are unallocated right now (up to \(gpu.maxPerNode) per node)")
    }
}
