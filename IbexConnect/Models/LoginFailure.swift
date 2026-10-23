import Foundation

/// Why a sign-in attempt failed, worked out from ssh's stderr plus a few
/// local checks, in terms the login window can act on.
nonisolated struct LoginFailure: Sendable, Equatable {
    enum Kind: Sendable {
        /// The login node resolves but nothing answers on port 22: the user
        /// is almost certainly off campus without the KAUST VPN.
        case vpn
        /// The login node's name doesn't resolve: no internet at all.
        case offline
        case passwordRejected
        case keyMissing
        case keyRejected
        case hostKeyChanged
        case other
    }

    struct Command: Sendable, Equatable, Identifiable {
        let label: String
        let command: String
        var id: String { command }
    }

    let kind: Kind
    let title: String
    let message: String
    var commands: [Command] = []
    /// Raw ssh output, for the cases the app couldn't classify.
    var detail: String?
}
