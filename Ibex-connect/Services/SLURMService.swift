import Foundation

actor SLURMService {
    private let ssh: SSHService
    private let config = ClusterConfig()

    init(ssh: SSHService) {
        self.ssh = ssh
    }

    // MARK: - GPU availability

    func queryGPUs() async throws -> [GPUInfo] {
        // grep keeps only GPU nodes so the transfer stays small; `|| true`
        // keeps the exit code 0 even if nothing matches.
        let result = try await ssh.run(
            "sinfo -N -h -O 'NodeHost:24,Gres:44,GresUsed:44,StateCompact:12' | grep -F 'gpu:' || true"
        )
        return Self.parseGPUAvailability(result.stdout)
    }

    /// Parses `sinfo -N -O NodeHost,Gres,GresUsed,StateCompact` output.
    /// Nodes appear once per partition they belong to, so rows are deduplicated by hostname.
    nonisolated static func parseGPUAvailability(_ output: String) -> [GPUInfo] {
        struct NodeGPUs {
            let type: String
            let total: Int
            let free: Int
        }

        var seenHosts = Set<String>()
        var nodes: [NodeGPUs] = []

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4 else { continue }
            let host = String(fields[0])
            let gres = String(fields[1])
            let gresUsed = String(fields[2])
            let stateField = String(fields[3])

            guard gres.contains("gpu:"), !seenHosts.contains(host) else { continue }
            seenHosts.insert(host)

            guard let (type, total) = parseGres(gres) else { continue }

            let base = stateField.prefix(while: \.isLetter).lowercased()
            let flags = stateField.dropFirst(base.count)

            // Unreachable or powered-down nodes contribute nothing.
            if flags.contains("*") || flags.contains("~") { continue }
            guard ["idle", "mix", "alloc", "allocated", "comp", "plnd"].contains(base) else { continue }

            let used = parseGres(gresUsed)?.count ?? 0
            // "Planned" nodes are already reserved for a scheduled job.
            let isPlanned = base == "plnd" || flags.contains("-")
            let free = isPlanned ? 0 : max(0, total - used)
            nodes.append(NodeGPUs(type: type, total: total, free: free))
        }

        var byType: [String: (free: Int, total: Int, maxPerNode: Int, largestFreeBlock: Int)] = [:]
        for node in nodes {
            var entry = byType[node.type] ?? (0, 0, 0, 0)
            entry.free += node.free
            entry.total += node.total
            entry.maxPerNode = max(entry.maxPerNode, node.total)
            entry.largestFreeBlock = max(entry.largestFreeBlock, node.free)
            byType[node.type] = entry
        }

        return byType
            .map {
                GPUInfo(
                    type: $0.key,
                    free: $0.value.free,
                    total: $0.value.total,
                    maxPerNode: $0.value.maxPerNode,
                    largestFreeBlock: $0.value.largestFreeBlock
                )
            }
            .sorted { $0.type < $1.type }
    }

    /// Extracts (type, count) from a GRES string like "gpu:v100:8(S:0-1)" or "gpu:p6000:0(IDX:N/A)".
    nonisolated static func parseGres(_ gres: String) -> (type: String, count: Int)? {
        guard let match = gres.firstMatch(of: /gpu:([A-Za-z0-9_]+):(\d+)/) else { return nil }
        return (String(match.1), Int(match.2) ?? 0)
    }

    // MARK: - Job queue

    func myJobs() async throws -> [QueuedJobSnapshot] {
        // %S is Slurm's estimated start time for queued jobs.
        let result = try await ssh.run("squeue --me -h -o '%i|%T|%j|%M|%l|%R|%b|%N|%S'")
        return Self.parseQueue(result.stdout)
    }

    nonisolated static func parseQueue(_ output: String) -> [QueuedJobSnapshot] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 8, !fields[0].isEmpty else { return nil }
            return QueuedJobSnapshot(
                id: fields[0],
                state: JobState(raw: fields[1]),
                name: fields[2],
                elapsed: fields[3],
                timeLimit: fields[4],
                reasonOrNode: fields[5].trimmingCharacters(in: CharacterSet(charactersIn: "()")),
                tresPerNode: fields[6],
                nodeList: fields[7],
                estimatedStart: fields.count >= 9 ? parseSlurmDate(fields[8]) : nil
            )
        }
    }

    /// Parses Slurm's "2026-07-29T02:26:00" timestamps. "N/A" and "Unknown" give nil.
    nonisolated static func parseSlurmDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "N/A", trimmed != "Unknown", trimmed != "(null)" else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: trimmed)
    }

    /// Extracts (type, count) from squeue's %b field, e.g. "gres/gpu:v100:1" or "gres/gpu:2".
    nonisolated static func parseTres(_ tres: String) -> (type: String, count: Int)? {
        if let match = tres.firstMatch(of: /gpu:([A-Za-z0-9_]+):(\d+)/) {
            return (String(match.1), Int(match.2) ?? 0)
        }
        if let match = tres.firstMatch(of: /gpu:(\d+)/) {
            return ("gpu", Int(match.1) ?? 0)
        }
        return nil
    }

    /// Final states for jobs that left the queue, via sacct.
    func finalStates(ids: [String]) async throws -> [String: JobState] {
        guard !ids.isEmpty else { return [:] }
        let list = ids.joined(separator: ",")
        let result = try await ssh.run("sacct -j \(list) -X -n -P -o JobID,State 2>/dev/null; true")
        return Self.parseFinalStates(result.stdout)
    }

    nonisolated static func parseFinalStates(_ output: String) -> [String: JobState] {
        var map: [String: JobState] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|")
            guard fields.count >= 2 else { continue }
            map[String(fields[0]).trimmingCharacters(in: .whitespaces)] = JobState(raw: String(fields[1]))
        }
        return map
    }

    /// Resolves the stdout file path for a job the app didn't submit.
    func stdOutPath(jobID: String) async -> String? {
        guard let result = try? await ssh.run("scontrol show job -o \(jobID) 2>/dev/null; true"),
              let match = result.stdout.firstMatch(of: /StdOut=(\S+)/)
        else { return nil }
        return String(match.1)
    }

    // MARK: - Submission

    func submitJob(config jobConfig: JobConfig) async throws -> String {
        _ = try await ssh.run("mkdir -p \(config.statusBaseDir)")

        let script = Self.buildJobScript(config: jobConfig)
        let scriptPath = "\(config.statusBaseDir)/submit-\(UUID().uuidString.prefix(8)).sh"
        try await ssh.writeRemoteFile(content: script, remotePath: scriptPath)

        let result = try await ssh.run("sbatch --parsable \(scriptPath) 2>&1")
        _ = try? await ssh.run("rm -f \(scriptPath)")

        // --parsable prints "jobid" or "jobid;cluster".
        let jobID = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ";").first.map(String.init) ?? ""

        guard !jobID.isEmpty, jobID.allSatisfy(\.isNumber) else {
            throw IbexError.jobSubmissionFailed(
                result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return jobID
    }

    nonisolated static func sanitizedJobName(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "job" : String(result.prefix(40))
    }

    nonisolated static func buildJobScript(config: JobConfig) -> String {
        let name = config.kind == .jupyter ? "jupyter" : sanitizedJobName(config.name)
        // No type means any model, which schedules far sooner.
        let gres = config.gpuType == GPUInfo.anyType
            ? "gpu:\(config.gpuCount)"
            : "gpu:\(config.gpuType):\(config.gpuCount)"
        let header = """
        #!/bin/bash
        #SBATCH --job-name=\(name)
        #SBATCH --gres=\(gres)
        #SBATCH --time=\(config.timeLimit)
        #SBATCH --mem=\(config.memoryGB)G
        #SBATCH --cpus-per-task=\(config.cpus)
        #SBATCH --output=.ibex-connect/job-%j.out

        STATUSDIR="$HOME/.ibex-connect/job-$SLURM_JOB_ID"
        mkdir -p "$STATUSDIR"
        hostname > "$STATUSDIR/node.txt"

        source /etc/profile.d/modules.sh 2>/dev/null || true
        """

        switch config.kind {
        case .jupyter:
            return header + """

            module load python/3.11.0 2>/dev/null || module load python/3.9.16 2>/dev/null || true
            export PATH="$HOME/.local/bin:$PATH"

            # Actually run jupyter rather than just looking for the file: the
            # launcher sits on a shared home and stays present even when the
            # interpreter behind it can't start (e.g. no python module loaded).
            if ! jupyter --version >/dev/null 2>&1; then
                echo "ERROR: jupyter is present but cannot run on $(hostname):"
                jupyter --version 2>&1 | head -5
                echo "Fix it from a login node with:  module load python/3.11.0 && pip install --user notebook"
                echo "failed" > "$STATUSDIR/status.txt"
                exit 1
            fi

            # The app supplies the token so it can build the link itself rather
            # than scraping it back out of the log. Without a token every API
            # call returns 403, which is what makes VS Code report the server as
            # unreachable, so it must always be set.
            SERVER_TOKEN='\(config.token)'

            # Prefer JupyterLab: it runs on jupyter_server 2, which is what VS
            # Code and a modern jupyterlab install expect. Classic Notebook 6 is
            # the fallback, and loads jupyterlab as an extension that crashes.
            start_jupyter() {
                if jupyter lab --version >/dev/null 2>&1; then
                    echo "[ibex-connect] Starting JupyterLab on $(hostname)..." >&2
                    exec jupyter lab --no-browser --ip=0.0.0.0 --port=8888 \\
                        --ServerApp.token="$SERVER_TOKEN"
                fi
                echo "[ibex-connect] Starting classic Notebook on $(hostname)..." >&2
                exec jupyter notebook --no-browser --ip=0.0.0.0 --port=8888 \\
                    --NotebookApp.token="$SERVER_TOKEN"
            }

            start_jupyter 2>&1 | while IFS= read -r line; do
                echo "$line"
                case "$line" in
                    *http://*[?\\&]token=*)
                        if [ ! -f "$STATUSDIR/url.txt" ]; then
                            echo "$line" > "$STATUSDIR/url.txt"
                            echo "ready" > "$STATUSDIR/status.txt"
                        fi
                        ;;
                esac
            done
            RC=${PIPESTATUS[0]}

            # Reached only once jupyter has exited. Flag it so the app reports
            # the failure straight away instead of waiting out its timeout, and
            # exit with jupyter's own status so the job isn't recorded COMPLETED.
            if [ ! -f "$STATUSDIR/url.txt" ]; then
                echo "[ibex-connect] Jupyter exited without printing a URL (exit $RC)."
                echo "failed" > "$STATUSDIR/status.txt"
            fi
            exit $RC
            """
        case .batch:
            return header + """

            cd "$HOME"
            echo "[ibex-connect] Job $SLURM_JOB_ID started on $(hostname)"
            echo "──────────────────────────────────────────"

            \(config.command)

            RC=$?
            echo "──────────────────────────────────────────"
            echo "[ibex-connect] Job finished with exit code $RC"
            """
        }
    }

    // MARK: - Jupyter session files

    func readNodeName(jobID: String) async throws -> String? {
        let content = try await ssh.readRemoteFile(remotePath: "\(config.statusDir(jobID: jobID))/node.txt")
        return content.isEmpty ? nil : content
    }

    /// Reads url.txt and extracts the actual port and token Jupyter chose.
    func readJupyterSession(jobID: String) async throws -> (port: Int, token: String?)? {
        let content = try await ssh.readRemoteFile(remotePath: "\(config.statusDir(jobID: jobID))/url.txt")
        return Self.parseJupyterURL(content)
    }

    func sessionFailed(jobID: String) async -> Bool {
        let content = try? await ssh.readRemoteFile(remotePath: "\(config.statusDir(jobID: jobID))/status.txt")
        return content == "failed"
    }

    static func parseJupyterURL(_ line: String) -> (port: Int, token: String?)? {
        if let match = line.firstMatch(of: /http:\/\/[^\s\/]+:(\d+)\/\S*[?&]token=([A-Za-z0-9]+)/) {
            return (Int(match.1) ?? 8888, String(match.2))
        }
        if let match = line.firstMatch(of: /http:\/\/[^\s\/]+:(\d+)\//) {
            return (Int(match.1) ?? 8888, nil)
        }
        return nil
    }

    // MARK: - Cancel / cleanup

    func cancelJob(id: String) async throws {
        _ = try await ssh.run("scancel \(id)")
    }

    /// Removes the status directory and captured output for one job.
    func cleanup(jobID: String) async {
        let dir = config.statusDir(jobID: jobID)
        let out = config.outputPath(jobID: jobID)
        _ = try? await ssh.run("rm -rf \(dir) \(out)")
    }

    /// Removes leftover submit scripts from previous runs (never touches job output).
    func cleanupStaleScripts() async {
        _ = try? await ssh.run("rm -f \(config.statusBaseDir)/submit-*.sh \(config.statusBaseDir)/submit.sh")
    }
}
