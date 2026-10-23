import Foundation
import Darwin

@Observable
@MainActor
final class TunnelManager {
    private let config = ClusterConfig()
    private(set) var tunnels: [String: SSHTunnel] = [:]

    /// Opens localhost:localPort → remoteHost:remotePort through the login node.
    ///
    /// The tunnel gets its own SSH connection (see `sshTunnelArgs`) so that the
    /// process we spawn is the one that owns the forward: if it is alive, the
    /// tunnel is up; when we kill it, the forward goes away.
    ///
    /// Success is confirmed by connecting to the local port rather than by
    /// guessing from elapsed time.
    func createTunnel(jobID: String, localPort: Int, remoteHost: String, remotePort: Int) async throws {
        if let existing = tunnels[jobID], existing.isActive {
            return
        }

        let tunnel = SSHTunnel(
            id: jobID,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = config.sshTunnelArgs + [
            "-N",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            config.sshTarget
        ]
        process.environment = config.sshEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        // Keep stderr: it carries the reason a forward was refused.
        let errPipe = Pipe()
        process.standardError = errPipe
        let errBuffer = ErrorBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errBuffer.append(String(decoding: data, as: UTF8.self))
        }

        try process.run()

        // Wait for the listener to come up, or for ssh to give up. The socket
        // probes are blocking syscalls, so they run off the main actor.
        var confirmed = false
        for _ in 0..<24 {
            if !process.isRunning { break }
            if await Task.detached(priority: .userInitiated, operation: {
                Self.canConnect(to: localPort)
            }).value {
                confirmed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard confirmed, process.isRunning else {
            if process.isRunning { process.terminate() }
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw IbexError.tunnelFailed(Self.explain(errBuffer.text, localPort: localPort))
        }

        errPipe.fileHandleForReading.readabilityHandler = nil
        tunnel.process = process
        tunnel.isActive = true
        tunnels[jobID] = tunnel
    }

    func destroyTunnel(jobID: String) {
        guard let tunnel = tunnels[jobID] else { return }
        tunnel.process?.terminate()
        tunnel.isActive = false
        tunnels.removeValue(forKey: jobID)
    }

    func destroyAllTunnels() {
        for id in tunnels.keys {
            destroyTunnel(jobID: id)
        }
    }

    /// Drops tunnels whose ssh process has died. Returns the job ids that were lost.
    @discardableResult
    func healthCheck() -> [String] {
        var lost: [String] = []
        for (id, tunnel) in tunnels {
            if let process = tunnel.process, !process.isRunning {
                tunnel.isActive = false
                tunnels.removeValue(forKey: id)
                lost.append(id)
            }
        }
        return lost
    }

    func isActive(jobID: String) -> Bool {
        tunnels[jobID]?.isActive ?? false
    }

    /// Picks a local port that nothing is listening on and no tunnel already uses.
    func nextAvailableLocalPort(startingAt start: Int = 8888) -> Int {
        let inUse = Set(tunnels.values.map(\.localPort))
        var port = start
        while port < start + 200 {
            if !inUse.contains(port), Self.isPortFree(port) {
                return port
            }
            port += 1
        }
        return start
    }

    /// Kills tunnels orphaned by a crash or a force-quit of a previous run.
    ///
    /// A tunnel is a child of the app, so a clean quit tears it down; but if the
    /// app dies without running its teardown, the ssh process is reparented to
    /// launchd and keeps holding its local port. Only orphans (parent pid 1) are
    /// killed, so tunnels belonging to another running instance are left alone.
    func reapOrphanedTunnels() async {
        let target = config.sshTarget
        let pids = await Task.detached(priority: .utility) {
            Self.orphanedTunnelPIDs(target: target)
        }.value
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }

    nonisolated static func orphanedTunnelPIDs(target: String) -> [pid_t] {
        guard let output = try? runPS() else { return [] }
        return parseOrphanedTunnels(output, target: target)
    }

    nonisolated static func parseOrphanedTunnels(_ psOutput: String, target: String) -> [pid_t] {
        psOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  parts[1] == "1"                       // orphaned
            else { return nil }
            let command = line.drop(while: { $0 != "/" })
            guard command.contains("/ssh"),
                  command.contains(" -L "),
                  command.contains("ControlPath=none"), // our tunnel signature
                  command.contains(target)
            else { return nil }
            return pid
        }
    }

    nonisolated private static func runPS() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func explain(_ stderr: String, localPort: Int) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Address already in use") || text.contains("cannot listen to port") {
            return "Local port \(localPort) is already in use."
        }
        if text.contains("Permission denied") {
            return "The cluster rejected the SSH key while opening the tunnel."
        }
        if text.isEmpty {
            return "The tunnel on local port \(localPort) did not come up."
        }
        return text
    }

    /// True if nothing is listening on 127.0.0.1:port.
    ///
    /// No SO_REUSEADDR here on purpose — with it set, macOS can hand back a
    /// port that another process is actively listening on, which would make a
    /// busy port look free.
    nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// True if something accepts a TCP connection on 127.0.0.1:port.
    nonisolated static func canConnect(to port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Thread-safe accumulator for a process's stderr.
private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock()
        buffer += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
