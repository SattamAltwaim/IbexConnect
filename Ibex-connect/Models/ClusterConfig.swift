import Foundation

nonisolated struct ClusterConfig: Sendable {
    let loginNode = "ilogin.ibex.kaust.edu.sa"
    let user = "tuuaimss"
    let keyPath = "\(NSHomeDirectory())/.ssh/id_ed25519"
    let remoteHome = "/home/tuuaimss"
    let controlPath = "/tmp/ibex-connect-%r@%h:%p"
    let controlPersist = 600
    let connectTimeout = 10

    var statusBaseDir: String { "\(remoteHome)/.ibex-connect" }
    var sshTarget: String { "\(user)@\(loginNode)" }

    func statusDir(jobID: String) -> String {
        "\(statusBaseDir)/job-\(jobID)"
    }

    func outputPath(jobID: String) -> String {
        "\(statusBaseDir)/job-\(jobID).out"
    }

    var sshBaseArgs: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=\(controlPersist)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-i", keyPath,
        ]
    }

    var sshRunArgs: [String] {
        ["-n"] + sshBaseArgs + [sshTarget]
    }

    /// Port forwards must NOT share the multiplexed connection. A `-L` request
    /// made by a ControlMaster client is handed to the master, which owns the
    /// listener; the client then exits immediately, so its lifetime says nothing
    /// about the tunnel, and the forward outlives the app. A dedicated
    /// connection ties the forward to the process we actually supervise.
    var sshTunnelArgs: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-i", keyPath,
        ]
    }
}
