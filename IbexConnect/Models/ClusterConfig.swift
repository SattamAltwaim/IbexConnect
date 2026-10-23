import Foundation

nonisolated struct ClusterConfig: Sendable {
    let loginNode = "ilogin.ibex.kaust.edu.sa"
    let controlPath = "/tmp/ibex-connect-%r@%h:%p"
    let controlPersist = 600
    let connectTimeout = 10

    static let defaultKeyPath = "\(NSHomeDirectory())/.ssh/id_ed25519"

    private static let userKey = "ibex-connect.username"
    private static let keyPathKey = "ibex-connect.ssh-key-path"

    /// The account the login window saved. Read on every access rather than
    /// captured at init, so the services' stored copies of this struct see a
    /// new account as soon as the user signs in.
    var user: String {
        UserDefaults.standard.string(forKey: Self.userKey) ?? ""
    }

    var keyPath: String {
        let saved = UserDefaults.standard.string(forKey: Self.keyPathKey) ?? ""
        return saved.isEmpty ? Self.defaultKeyPath : saved
    }

    var hasAccount: Bool { !user.isEmpty }

    static func saveAccount(user: String, keyPath: String) {
        let defaults = UserDefaults.standard
        defaults.set(user.trimmingCharacters(in: .whitespacesAndNewlines), forKey: userKey)
        let path = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(path == defaultKeyPath ? "" : path, forKey: keyPathKey)
    }

    var remoteHome: String { "/home/\(user)" }
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
