import Foundation

/// Streams a remote job's output file into `text` by running `tail -F` over SSH.
/// Raw chunks are collected on a background queue and flushed to the main actor
/// on a timer, with the in-memory text capped so UI updates stay cheap.
@Observable
@MainActor
final class OutputStreamer {
    private static let maxTextSize = 60_000
    private static let flushInterval: TimeInterval = 0.8

    private(set) var text = ""
    /// Job id currently being streamed, if any.
    private(set) var jobID: String?

    private let config = ClusterConfig()
    private var pending = ""
    private var process: Process?
    private var readHandle: FileHandle?
    private var flushTimer: Timer?
    private var generation = 0

    /// Starts streaming `remotePath` for `jobID`, replacing any previous stream.
    /// Re-attaches automatically if the previous stream process died.
    func attach(jobID: String, remotePath: String) {
        if self.jobID == jobID, let process, process.isRunning { return }
        detach()
        self.jobID = jobID
        generation += 1
        let currentGeneration = generation

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -n: no stdin; 2>/dev/null on the remote side hides tail's
        // "cannot open" complaints while the job is still queued.
        process.arguments = config.sshRunArgs + ["tail -n +1 -F \(remotePath) 2>/dev/null"]
        process.environment = config.sshEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self.appendPending(chunk, ifGeneration: currentGeneration)
            }
        }

        do {
            try process.run()
            self.process = process
            self.readHandle = pipe.fileHandleForReading
        } catch {
            text = "Could not start the output stream: \(error.localizedDescription)\n"
            return
        }

        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flush()
            }
        }
    }

    /// Stops streaming and clears the buffer.
    func detach() {
        generation += 1
        flushTimer?.invalidate()
        flushTimer = nil
        // Clear the handler before terminating, otherwise it keeps firing on
        // the dead pipe and holds the file handle open.
        readHandle?.readabilityHandler = nil
        readHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        jobID = nil
        pending = ""
        text = ""
    }

    /// True if the stream process died while a job is still being watched.
    var streamBroken: Bool {
        jobID != nil && process?.isRunning != true
    }

    private func appendPending(_ chunk: String, ifGeneration expected: Int) {
        guard generation == expected else { return }
        pending += chunk
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        text += pending
        pending = ""
        if text.count > Self.maxTextSize {
            // Keep the tail; cut at a line boundary so the first line isn't garbled.
            var trimmed = String(text.suffix(Self.maxTextSize))
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            }
            text = "…(older output trimmed)…\n" + trimmed
        }
    }
}
