import Foundation

@Observable
final class FileTransferService {
    private let config = ClusterConfig()

    var isTransferring = false
    var progressText = ""

    func transferFile(localPath: String, remotePath: String) async throws {
        isTransferring = true
        progressText = "Starting transfer..."
        defer {
            isTransferring = false
            progressText = ""
        }

        let isDir = FileManager.default.isDirectory(atPath: localPath)
        let result: SSHResult

        if isDir {
            result = try await runTransfer(
                executable: "/usr/bin/rsync",
                arguments: [
                    "-avz", "--progress",
                    "-e", "ssh \(config.sshBaseArgs.joined(separator: " "))",
                    localPath,
                    "\(config.sshTarget):\(remotePath)"
                ]
            )
        } else {
            result = try await runTransfer(
                executable: "/usr/bin/scp",
                arguments: config.sshBaseArgs + [
                    localPath,
                    "\(config.sshTarget):\(remotePath)"
                ]
            )
        }

        if result.exitCode != 0 {
            throw IbexError.transferFailed(result.stderr)
        }

        progressText = "Transfer complete"
    }

    private nonisolated func runTransfer(executable: String, arguments: [String]) async throws -> SSHResult {
        // SSHService.execute drains output while the process runs, so large
        // rsync --progress output can't deadlock the transfer. No deadline:
        // a big folder can legitimately take much longer than a command does.
        try await SSHService.execute(path: executable, arguments: arguments, timeout: nil)
    }
}

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
