import Foundation

nonisolated enum IbexError: LocalizedError {
    case sshConnectionFailed(String)
    case commandFailed(exitCode: Int32, stderr: String)
    case parseError(String)
    case jobSubmissionFailed(String)
    case tunnelFailed(String)
    case transferFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .sshConnectionFailed(let msg): "SSH connection failed: \(msg)"
        case .commandFailed(let code, let stderr): "Command failed (exit \(code)): \(stderr)"
        case .parseError(let msg): "Parse error: \(msg)"
        case .jobSubmissionFailed(let msg): "Job submission failed: \(msg)"
        case .tunnelFailed(let msg): "Tunnel failed: \(msg)"
        case .transferFailed(let msg): "Transfer failed: \(msg)"
        case .timeout(let msg): "Timeout: \(msg)"
        }
    }
}
