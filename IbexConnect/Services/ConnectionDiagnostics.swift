import Foundation
import Network

/// Turns a failed ssh sign-in into something the user can fix.
nonisolated enum ConnectionDiagnostics {
    enum Reachability: Sendable {
        case reachable
        case unresolvable
        case unreachable
    }

    static func diagnose(stderr: String, config: ClusterConfig) async -> LoginFailure {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPath = config.keyPath
        let shortKey = keyPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let registerKey = LoginFailure.Command(
            label: "Register the key on Ibex (asks for your KAUST password once)",
            command: "ssh-copy-id -i \(shortKey).pub \(config.sshTarget)"
        )

        if !FileManager.default.fileExists(atPath: keyPath) {
            return LoginFailure(
                kind: .keyMissing,
                title: "No SSH key at \(shortKey)",
                message: "IbexConnect signs in with an SSH key, not a password. "
                    + "Create one in Terminal and register it on Ibex, then try again.",
                commands: [
                    LoginFailure.Command(
                        label: "Create a key",
                        command: "ssh-keygen -t ed25519 -f \(shortKey)"
                    ),
                    registerKey,
                ]
            )
        }

        if err.contains("Permission denied") {
            return LoginFailure(
                kind: .keyRejected,
                title: "Ibex rejected the sign-in",
                message: "Either the username is wrong, or the key at \(shortKey) isn't registered "
                    + "for \(config.user) on Ibex. If the key has a passphrase, it also needs to be "
                    + "loaded into ssh-agent first.",
                commands: [
                    registerKey,
                    LoginFailure.Command(
                        label: "Load a passphrase-protected key",
                        command: "ssh-add --apple-use-keychain \(shortKey)"
                    ),
                ]
            )
        }

        if err.contains("Host key verification failed") || err.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return LoginFailure(
                kind: .hostKeyChanged,
                title: "The login node's host key changed",
                message: "ssh refuses to connect because \(config.loginNode) no longer matches the key saved "
                    + "in ~/.ssh/known_hosts. If Ibex announced a maintenance that replaced it, forget the old one "
                    + "and try again.",
                commands: [
                    LoginFailure.Command(
                        label: "Forget the old host key",
                        command: "ssh-keygen -R \(config.loginNode)"
                    ),
                ],
                detail: err
            )
        }

        // ssh didn't say anything we recognise, so find out whether the login
        // node can be reached at all. Its name only resolves on the KAUST
        // network, so off the VPN the lookup itself fails; a public site is
        // probed to tell that apart from having no internet at all.
        let vpn = LoginFailure(
            kind: .vpn,
            title: "Ibex isn't reachable from this network",
            message: "Ibex only accepts connections from inside KAUST. If you're off campus, "
                + "connect to the KAUST VPN and try again.",
            detail: err.isEmpty ? nil : err
        )
        switch await probe(host: config.loginNode, port: 22, timeout: .seconds(6)) {
        case .unresolvable:
            if await probe(host: "www.kaust.edu.sa", port: 443, timeout: .seconds(6)) == .unresolvable {
                return LoginFailure(
                    kind: .offline,
                    title: "You're offline",
                    message: "Your Mac doesn't seem to have an internet connection. "
                        + "Check your network, then connect to the KAUST VPN if you're off campus.",
                    detail: err.isEmpty ? nil : err
                )
            }
            return vpn
        case .unreachable:
            return vpn
        case .reachable:
            return LoginFailure(
                kind: .other,
                title: "Couldn't sign in to Ibex",
                message: err.isEmpty
                    ? "ssh exited without saying why. Try again, or check that `ssh \(config.sshTarget)` works in Terminal."
                    : err
            )
        }
    }

    /// Opens a TCP connection and reports whether anything answered. A host
    /// that never answers is reported as unreachable once `timeout` elapses.
    static func probe(host: String, port: UInt16, timeout: Duration) async -> Reachability {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )
        let (stream, continuation) = AsyncStream<Reachability>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.yield(.reachable)
            case .failed(let error), .waiting(let error):
                continuation.yield(classify(error))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))

        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(.unreachable)
        }
        defer {
            timer.cancel()
            connection.cancel()
        }

        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .unreachable
    }

    private static func classify(_ error: NWError) -> Reachability {
        if case .dns = error { return .unresolvable }
        return .unreachable
    }
}
