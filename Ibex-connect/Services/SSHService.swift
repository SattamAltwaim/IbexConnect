import Foundation

nonisolated struct SSHResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

actor SSHService {
    private let config = ClusterConfig()
    private let marker = "___IBEX_START___"

    /// Runs a command on the login node. The marker lets us strip the login banner.
    func run(_ command: String) async throws -> SSHResult {
        let wrappedCommand = "echo '\(marker)'; \(command)"
        let args = config.sshRunArgs + [wrappedCommand]
        let result = try await Self.execute(path: "/usr/bin/ssh", arguments: args)

        let stdout = Self.stripBanner(result.stdout, marker: marker)
        if result.exitCode != 0 && stdout.isEmpty {
            throw IbexError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return SSHResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr)
    }

    func writeRemoteFile(content: String, remotePath: String) async throws {
        let args = config.sshBaseArgs + [config.sshTarget, "cat > \(remotePath)"]
        let result = try await Self.execute(
            path: "/usr/bin/ssh",
            arguments: args,
            stdin: content.data(using: .utf8) ?? Data()
        )
        if result.exitCode != 0 {
            throw IbexError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    func readRemoteFile(remotePath: String) async throws -> String {
        let result = try await run("cat \(remotePath) 2>/dev/null; true")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func connect() async throws {
        // Reuse an existing control master if one is alive.
        let checkArgs = config.sshBaseArgs + ["-O", "check", config.sshTarget]
        let check = try await Self.execute(path: "/usr/bin/ssh", arguments: checkArgs)
        if check.exitCode == 0 { return }

        let connectArgs = config.sshRunArgs + ["echo connected"]
        let result = try await Self.execute(path: "/usr/bin/ssh", arguments: connectArgs)
        if result.exitCode != 0 {
            // Raw stderr: ConnectionDiagnostics reads it to work out what
            // went wrong, so it must not be reworded here.
            throw IbexError.sshConnectionFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func isConnected() async -> Bool {
        let args = config.sshBaseArgs + ["-O", "check", config.sshTarget]
        let result = try? await Self.execute(path: "/usr/bin/ssh", arguments: args)
        return result?.exitCode == 0
    }

    func disconnect() async {
        let args = config.sshBaseArgs + ["-O", "exit", config.sshTarget]
        _ = try? await Self.execute(path: "/usr/bin/ssh", arguments: args)
    }

    /// Closes any control master left over from a previous run before we start
    /// using it. A master can outlive the app by ControlPersist seconds, and an
    /// older build could leave port forwards attached to it that keep local
    /// ports bound. Starting from a fresh master avoids inheriting that state.
    func resetControlMaster() async {
        await disconnect()
    }

    nonisolated static func stripBanner(_ output: String, marker: String) -> String {
        guard let range = output.range(of: marker) else { return output }
        return output[range.upperBound...].trimmingCharacters(in: .newlines)
    }

    // MARK: - Process execution

    /// Runs a process and captures its output. The pipes are drained *while*
    /// the process runs — draining only after exit deadlocks as soon as the
    /// output exceeds the 64 KB pipe buffer (large sinfo listings, file reads).
    nonisolated static func execute(
        path: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval? = 45
    ) async throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        try process.run()

        if let stdin, let stdinPipe {
            DispatchQueue.global(qos: .userInitiated).async {
                // Errors here surface via the process exit code instead.
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        // A wedged ssh (dead network, unresponsive login node) would otherwise
        // hang the caller forever, since we wait on its pipes closing.
        let watchdog: Task<Void, Never>? = timeout.map { seconds in
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled, process.isRunning {
                    process.terminate()
                }
            }
        }
        defer { watchdog?.cancel() }

        async let outData = readToEnd(stdoutPipe.fileHandleForReading)
        async let errData = readToEnd(stderrPipe.fileHandleForReading)
        let (out, err) = await (outData, errData)
        await waitUntilExit(process)

        return SSHResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    nonisolated private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    nonisolated private static func waitUntilExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
