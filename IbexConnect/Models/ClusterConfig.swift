import Foundation

nonisolated struct ClusterConfig: Sendable {
    let loginNode = "ilogin.ibex.kaust.edu.sa"
    let controlPath = "/tmp/ibex-connect-%r@%h:%p"
    let controlPersist = 600
    let connectTimeout = 10

    static let defaultKeyPath = "\(NSHomeDirectory())/.ssh/id_ed25519"

    private static let userKey = "ibex-connect.username"
    private static let authMethodKey = "ibex-connect.auth-method"
    private static let keyPathKey = "ibex-connect.ssh-key-path"

    /// The account the login window saved. Read on every access rather than
    /// captured at init, so the services' stored copies of this struct see a
    /// new account as soon as the user signs in.
    var user: String {
        UserDefaults.standard.string(forKey: Self.userKey) ?? ""
    }

    /// Password unless the user chose a key: new users have a KAUST
    /// password, and most don't have a key registered on Ibex yet.
    var authMethod: AuthMethod {
        AuthMethod(rawValue: UserDefaults.standard.string(forKey: Self.authMethodKey) ?? "") ?? .password
    }

    var keyPath: String {
        let saved = UserDefaults.standard.string(forKey: Self.keyPathKey) ?? ""
        return saved.isEmpty ? Self.defaultKeyPath : saved
    }

    var hasAccount: Bool { !user.isEmpty }

    static func saveAccount(user: String, authMethod: AuthMethod, keyPath: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(user.trimmingCharacters(in: .whitespacesAndNewlines), forKey: userKey)
        defaults.set(authMethod.rawValue, forKey: authMethodKey)
        if let keyPath {
            let path = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(path == defaultKeyPath ? "" : path, forKey: keyPathKey)
        }
    }

    /// Environment for every ssh (and scp/rsync, whose ssh inherits it).
    /// With a password, ssh is pointed at the askpass helper and the
    /// password rides along in a variable the helper prints.
    var sshEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        guard authMethod == .password,
              let password = SessionPassword.current,
              let helper = AskpassHelper.path
        else { return environment }
        environment["SSH_ASKPASS"] = helper
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[AskpassHelper.passwordVariable] = password
        return environment
    }

    /// How ssh authenticates. BatchMode is only for keys: it switches off
    /// every prompt, the askpass one included.
    private var authArgs: [String] {
        switch authMethod {
        case .key:
            ["-o", "BatchMode=yes", "-i", keyPath]
        case .password:
            [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        }
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
        authArgs + [
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=\(controlPersist)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
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
        authArgs + [
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]
    }
}
