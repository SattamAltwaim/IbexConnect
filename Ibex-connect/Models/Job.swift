import Foundation

nonisolated enum JobState: Equatable, Sendable {
    case pending
    case running
    case completing
    case configuring
    case completed
    case failed
    case cancelled
    case timeout
    case nodeFail
    case outOfMemory
    case preempted
    case suspended
    case unknown(String)

    /// Parses a Slurm state string. Handles suffixes like "CANCELLED by 219709".
    init(raw: String) {
        let firstWord = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        switch firstWord.uppercased() {
        case "PENDING": self = .pending
        case "RUNNING": self = .running
        case "COMPLETING": self = .completing
        case "CONFIGURING": self = .configuring
        case "COMPLETED": self = .completed
        case "FAILED": self = .failed
        case "CANCELLED": self = .cancelled
        case "TIMEOUT": self = .timeout
        case "NODE_FAIL": self = .nodeFail
        case "OUT_OF_MEMORY", "OUT_OF_ME+": self = .outOfMemory
        case "PREEMPTED": self = .preempted
        case "SUSPENDED": self = .suspended
        default: self = .unknown(firstWord)
        }
    }

    /// True while the job still occupies a slot in the queue (squeue lists it).
    var isActive: Bool {
        switch self {
        case .pending, .running, .completing, .configuring, .suspended: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .pending: "Queued"
        case .running: "Running"
        case .completing: "Finishing"
        case .configuring: "Starting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timeout: "Time limit reached"
        case .nodeFail: "Node failure"
        case .outOfMemory: "Out of memory"
        case .preempted: "Preempted"
        case .suspended: "Suspended"
        case .unknown(let raw): raw.isEmpty ? "Unknown" : raw.capitalized
        }
    }
}

nonisolated enum JobKind: String, Codable, Sendable {
    case jupyter
    case batch
}

nonisolated struct JobConfig: Sendable {
    let kind: JobKind
    let name: String
    let gpuType: String
    let gpuCount: Int
    let hours: Int
    let memoryGB: Int
    let cpus: Int
    /// Shell command(s) to run — batch jobs only.
    let command: String

    var timeLimit: String {
        String(format: "%d:00:00", hours)
    }
}

/// Minimal persisted record so jobs survive app restarts.
nonisolated struct JobRecord: Codable, Sendable {
    let id: String
    let kind: JobKind
    let name: String
    let gpuType: String
    let gpuCount: Int
    let submittedAt: Date
}

@Observable
final class Job: Identifiable {
    let id: String
    let kind: JobKind
    let name: String
    let gpuType: String
    let gpuCount: Int
    let submittedAt: Date?
    /// True if this job was submitted from this app (vs. adopted from the queue).
    let submittedByApp: Bool

    var state: JobState = .pending
    var nodeName: String?
    var elapsed: String = ""
    var timeLimit: String = ""
    /// Slurm's reason while the job is queued, e.g. "Priority" or "Resources".
    var pendingReason: String?
    /// Slurm's estimate of when a queued job will start.
    var estimatedStart: Date?
    /// Absolute remote path of the job's stdout/stderr file, once known.
    var outputPath: String?

    // Jupyter session details
    var jupyterSetupStarted = false
    /// What the app is currently waiting on while bringing Jupyter up.
    var setupStage: String?
    var localPort: Int?
    var remotePort: Int?
    var token: String?
    var tunnelActive = false
    var tunnelError: String?

    var isFinished: Bool { !state.isActive }

    /// The link to open in a browser or paste into VS Code.
    var jupyterLink: String? {
        guard let port = localPort, tunnelActive else { return nil }
        if let token, !token.isEmpty {
            return "http://localhost:\(port)/?token=\(token)"
        }
        return "http://localhost:\(port)"
    }

    init(
        id: String,
        kind: JobKind,
        name: String,
        gpuType: String,
        gpuCount: Int,
        submittedAt: Date?,
        submittedByApp: Bool
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.gpuType = gpuType
        self.gpuCount = gpuCount
        self.submittedAt = submittedAt
        self.submittedByApp = submittedByApp
    }

    convenience init(id: String, config: JobConfig) {
        self.init(
            id: id,
            kind: config.kind,
            name: config.name,
            gpuType: config.gpuType,
            gpuCount: config.gpuCount,
            submittedAt: Date(),
            submittedByApp: true
        )
        self.timeLimit = config.timeLimit
    }

    convenience init(record: JobRecord) {
        self.init(
            id: record.id,
            kind: record.kind,
            name: record.name,
            gpuType: record.gpuType,
            gpuCount: record.gpuCount,
            submittedAt: record.submittedAt,
            submittedByApp: true
        )
    }

    var record: JobRecord {
        JobRecord(
            id: id,
            kind: kind,
            name: name,
            gpuType: gpuType,
            gpuCount: gpuCount,
            submittedAt: submittedAt ?? Date()
        )
    }
}

/// One row of `squeue --me` output.
nonisolated struct QueuedJobSnapshot: Sendable {
    let id: String
    let state: JobState
    let name: String
    let elapsed: String
    let timeLimit: String
    let reasonOrNode: String
    let tresPerNode: String
    let nodeList: String
    let estimatedStart: Date?
}
