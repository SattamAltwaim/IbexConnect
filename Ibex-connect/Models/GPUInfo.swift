import Foundation

nonisolated struct GPUInfo: Identifiable, Sendable, Equatable {
    var id: String { type }
    /// Slurm GRES type, e.g. "a100", "v100", "gtx_1080_ti".
    let type: String
    /// GPUs not allocated to any job right now, across usable nodes.
    let free: Int
    /// Total GPUs on usable (idle/mixed/allocated) nodes.
    let total: Int
    /// Largest GPU count on a single node — the most one job can request.
    let maxPerNode: Int
    /// Most free GPUs available on any single node. A job's --gres must fit on
    /// one node, so this is the largest request that can start right now.
    let largestFreeBlock: Int

    /// Sentinel type meaning "don't pin a GPU model" — submitted as `--gres=gpu:N`.
    static let anyType = "any"

    var isAny: Bool { type == Self.anyType }

    /// "GTX 1080 TI" style display name.
    var displayName: String {
        isAny ? "ANY GPU" : type.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    /// A combined option covering every type. Pinning a model can add days to
    /// the queue, so letting Slurm pick whichever node frees up first is
    /// usually much faster.
    static func anyOption(from list: [GPUInfo]) -> GPUInfo? {
        guard !list.isEmpty else { return nil }
        return GPUInfo(
            type: anyType,
            free: list.reduce(0) { $0 + $1.free },
            total: list.reduce(0) { $0 + $1.total },
            maxPerNode: list.map(\.maxPerNode).max() ?? 1,
            largestFreeBlock: list.map(\.largestFreeBlock).max() ?? 0
        )
    }
}
