import Foundation
import SwiftUI

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

@Observable
@MainActor
final class AppViewModel {
    private(set) var gpuList: [GPUInfo] = []
    private(set) var jobs: [Job] = []
    private(set) var connection: ConnectionState = .disconnected
    private(set) var isLoadingGPUs = false
    var statusMessage = "Not connected"
    var error: IbexError?

    /// The login window stays up until the first successful connection, and
    /// comes back when the user signs out.
    private(set) var showLogin = true
    private(set) var loginFailure: LoginFailure?

    /// Job whose output is shown in the terminal panel.
    var selectedJobID: String?

    let sshService: SSHService
    let slurmService: SLURMService
    let tunnelManager = TunnelManager()
    let transferService = FileTransferService()
    let outputStreamer = OutputStreamer()

    private let config = ClusterConfig()
    private var gpuPollingTask: Task<Void, Never>?
    private var jobPollingTask: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []

    /// Submissions are remembered per account, so switching users doesn't
    /// adopt someone else's jobs.
    private var recordsKey: String { "ibex-connect.submitted-jobs.\(config.user)" }

    init() {
        let ssh = SSHService()
        self.sshService = ssh
        self.slurmService = SLURMService(ssh: ssh)
    }

    var selectedJob: Job? {
        jobs.first { $0.id == selectedJobID }
    }

    var username: String { config.user }
    var savedKeyPath: String { config.keyPath }
    var hasSavedAccount: Bool { config.hasAccount }
    var remoteHome: String { config.remoteHome }
    var loginNode: String { config.loginNode }

    // MARK: - Connection

    /// Called once when the window appears. With a saved account the app
    /// signs in straight away; otherwise the login window waits for one.
    func onAppear() async {
        guard connection == .disconnected else { return }
        installSignalHandlers()
        if config.hasAccount {
            await connect()
        }
    }

    /// Saves the account and connects with it.
    func signIn(user: String, keyPath: String) async {
        ClusterConfig.saveAccount(user: user, keyPath: keyPath)
        await connect()
    }

    /// Drops the connection and returns to the login window. Jobs keep
    /// running on the cluster, as on quit.
    func signOut() async {
        stopPolling()
        tunnelManager.destroyAllTunnels()
        outputStreamer.detach()
        await sshService.disconnect()
        jobs = []
        gpuList = []
        selectedJobID = nil
        connection = .disconnected
        statusMessage = "Not connected"
        loginFailure = nil
        showLogin = true
    }

    /// Tears tunnels down when the app is killed rather than quit normally.
    /// Without this the ssh children survive and keep their local ports bound.
    private func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    self.onTerminate()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func connect() async {
        connection = .connecting
        loginFailure = nil
        statusMessage = "Connecting to \(config.loginNode)…"
        // Clear state a previous run may have left behind: a control master can
        // still hold port forwards, and a force-quit can orphan tunnels. Both
        // would keep local ports occupied.
        await sshService.resetControlMaster()
        await tunnelManager.reapOrphanedTunnels()
        do {
            try await sshService.connect()
            connection = .connected
            showLogin = false
            statusMessage = "Connected"
            await slurmService.cleanupStaleScripts()
            await adoptExistingJobs()
            await refreshJobs()
            await refreshGPUs()
            startPolling()
        } catch {
            connection = .disconnected
            statusMessage = "Connection failed"
            let stderr: String
            if case .sshConnectionFailed(let msg) = error as? IbexError {
                stderr = msg
            } else {
                stderr = error.localizedDescription
            }
            let failure = await ConnectionDiagnostics.diagnose(stderr: stderr, config: config)
            loginFailure = failure
            if !showLogin {
                // Reconnecting from the dashboard: there is no login window to
                // show the diagnosis, so it goes through the alert instead.
                self.error = .sshConnectionFailed("\(failure.title). \(failure.message)")
            }
        }
    }

    /// Rebuilds the job list from persisted submissions and whatever is in the queue.
    private func adoptExistingJobs() async {
        var restored: [Job] = []
        for record in loadRecords() {
            let job = Job(record: record)
            job.outputPath = config.outputPath(jobID: record.id)
            restored.append(job)
        }
        jobs = restored.sorted { ($0.submittedAt ?? .distantPast) > ($1.submittedAt ?? .distantPast) }
    }

    // MARK: - GPUs

    func refreshGPUs() async {
        guard connection == .connected else { return }
        isLoadingGPUs = true
        defer { isLoadingGPUs = false }
        do {
            gpuList = try await slurmService.queryGPUs()
        } catch {
            statusMessage = "Couldn't refresh GPU availability"
        }
    }

    // MARK: - Jobs

    func submitJob(config jobConfig: JobConfig) async throws {
        let jobID = try await slurmService.submitJob(config: jobConfig)
        let job = Job(id: jobID, config: jobConfig)
        job.outputPath = config.outputPath(jobID: jobID)
        jobs.insert(job, at: 0)
        saveRecord(job.record)
        selectedJobID = jobID
        syncStreamer()
        statusMessage = "Job \(jobID) submitted — waiting in queue"
    }

    /// Cancels a job that is still queued or running.
    func cancelJob(_ job: Job) async {
        do {
            try await slurmService.cancelJob(id: job.id)
            statusMessage = "Job \(job.id) cancelled"
            await refreshJobs()
        } catch {
            self.error = (error as? IbexError)
                ?? .commandFailed(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// Removes a finished job from the list and deletes its captured output.
    func removeJob(_ job: Job) async {
        guard job.isFinished else { return }
        tunnelManager.destroyTunnel(jobID: job.id)
        jobs.removeAll { $0.id == job.id }
        deleteRecord(id: job.id)
        if selectedJobID == job.id {
            selectedJobID = nil
            syncStreamer()
        }
        if job.submittedByApp {
            await slurmService.cleanup(jobID: job.id)
        }
    }

    func refreshAll() async {
        if connection == .disconnected {
            await connect()
            return
        }
        await refreshGPUs()
        await refreshJobs()
    }

    // MARK: - Polling

    private func startPolling() {
        gpuPollingTask?.cancel()
        jobPollingTask?.cancel()
        gpuPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshGPUs()
            }
        }
        jobPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                await self?.refreshJobs()
                self?.reconcileTunnels()
            }
        }
    }

    private func stopPolling() {
        gpuPollingTask?.cancel()
        jobPollingTask?.cancel()
    }

    private func refreshJobs() async {
        guard connection == .connected else { return }

        let snapshots: [QueuedJobSnapshot]
        do {
            snapshots = try await slurmService.myJobs()
        } catch {
            if await !sshService.isConnected() {
                connection = .disconnected
                statusMessage = "Connection lost — click Reconnect"
                stopPolling()
            }
            return
        }

        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var vanished: [Job] = []

        for job in jobs {
            if let snap = byID[job.id] {
                apply(snap, to: job)
            } else if !job.isFinished {
                vanished.append(job)
            }
        }

        // Jobs in the queue that the app doesn't know yet (submitted elsewhere).
        let knownIDs = Set(jobs.map(\.id))
        for snap in snapshots where !knownIDs.contains(snap.id) {
            adopt(snap)
        }

        // Jobs that left the queue: look up their final state once.
        if !vanished.isEmpty {
            let finals = (try? await slurmService.finalStates(ids: vanished.map(\.id))) ?? [:]
            for job in vanished {
                job.state = finals[job.id] ?? .unknown("FINISHED")
                job.pendingReason = nil
                tunnelManager.destroyTunnel(jobID: job.id)
                job.tunnelActive = false
            }
        }

        syncStreamer()
    }

    private func apply(_ snap: QueuedJobSnapshot, to job: Job) {
        let oldState = job.state
        job.state = snap.state
        job.elapsed = snap.elapsed
        job.timeLimit = snap.timeLimit

        switch snap.state {
        case .pending:
            job.pendingReason = Self.friendlyReason(snap.reasonOrNode)
            job.estimatedStart = snap.estimatedStart
        case .running, .completing:
            job.pendingReason = nil
            job.estimatedStart = nil
            if job.nodeName == nil, !snap.nodeList.isEmpty {
                job.nodeName = snap.nodeList
            }
        default:
            job.pendingReason = nil
            job.estimatedStart = nil
        }

        if job.kind == .jupyter, snap.state == .running, !job.jupyterSetupStarted {
            startJupyterSetup(job)
        }
        if oldState.isActive, !snap.state.isActive {
            tunnelManager.destroyTunnel(jobID: job.id)
            job.tunnelActive = false
        }
    }

    private func adopt(_ snap: QueuedJobSnapshot) {
        let kind: JobKind = snap.name == "jupyter" ? .jupyter : .batch
        let gres = SLURMService.parseTres(snap.tresPerNode)
        let job = Job(
            id: snap.id,
            kind: kind,
            name: snap.name,
            gpuType: gres?.type ?? "gpu",
            gpuCount: gres?.count ?? 0,
            submittedAt: nil,
            submittedByApp: false
        )
        apply(snap, to: job)
        jobs.append(job)

        Task { [weak self] in
            job.outputPath = await self?.slurmService.stdOutPath(jobID: snap.id)
            self?.syncStreamer()
        }
    }

    static func friendlyReason(_ raw: String) -> String? {
        switch raw {
        case "", "None": nil
        case "Priority": "Waiting in queue behind higher-priority jobs"
        case "Resources": "Waiting for GPUs to free up"
        case "Dependency": "Waiting for another job to finish"
        case let r where r.hasPrefix("QOS"): "Account usage limit reached (\(r))"
        case let r where r.hasPrefix("ReqNodeNotAvail"):
            // Slurm's wording sounds fatal, but this is an ordinary queue wait:
            // it just means some candidate nodes are offline for maintenance.
            "Waiting for free GPUs — some nodes of this type are offline for maintenance"
        default: raw
        }
    }

    // MARK: - Jupyter session

    private func startJupyterSetup(_ job: Job) {
        job.jupyterSetupStarted = true
        job.tunnelError = nil
        job.setupStage = "Waiting for the compute node…"

        Task { [weak self] in
            guard let self else { return }
            // Whatever happens below, the row must never be left on a spinner.
            defer { job.setupStage = nil }

            // Deadlines are wall-clock, not iteration counts: every probe is an
            // SSH round trip serialised behind the polling loops, so counting
            // iterations would silently shorten the window on a slow link.
            let nodeName: String
            do {
                nodeName = try await self.waitForNode(job: job, timeout: 60)
            } catch {
                job.tunnelError = "The job is running but never reported its node. Check the output below."
                return
            }
            job.nodeName = nodeName

            job.setupStage = "Starting Jupyter on \(nodeName)…"
            let session: (port: Int, token: String?)
            do {
                session = try await self.waitForJupyter(job: job, timeout: 240)
            } catch let error as IbexError {
                job.tunnelError = error.localizedDescription
                return
            } catch {
                job.tunnelError = "Jupyter setup failed: \(error.localizedDescription)"
                return
            }

            job.remotePort = session.port
            // Ours is authoritative when we submitted the job. Otherwise fall
            // back to the file the job script wrote, then to whatever the
            // server printed — a supplied token is logged as "token=...", so
            // parsing the log alone is not enough.
            if job.token == nil {
                job.token = await self.slurmService.readToken(jobID: job.id) ?? session.token
            }
            if job.token == nil {
                job.tunnelError = "No access token found for this session, so the link will not authenticate. "
                    + "It was most likely started by an older build — resubmit to get a working link."
            }
            job.setupStage = "Opening the tunnel…"

            var lastError: String?
            for attempt in 0..<4 {
                let localPort = self.tunnelManager.nextAvailableLocalPort(startingAt: 8888 + attempt)
                do {
                    try await self.tunnelManager.createTunnel(
                        jobID: job.id,
                        localPort: localPort,
                        remoteHost: nodeName,
                        remotePort: session.port
                    )
                    job.localPort = localPort
                    job.tunnelActive = true
                    self.statusMessage = "Jupyter ready on localhost:\(localPort)"
                    return
                } catch {
                    lastError = (error as? IbexError)?.localizedDescription ?? error.localizedDescription
                }
            }
            job.tunnelError = "Couldn't open a local tunnel. \(lastError ?? "Unknown error.")"
        }
    }

    /// Polls for node.txt until it appears or `timeout` seconds elapse.
    private func waitForNode(job: Job, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let node = try? await slurmService.readNodeName(jobID: job.id), !node.isEmpty {
                return node
            }
            guard job.state.isActive else { throw IbexError.timeout("Job ended before it reported a node") }
            try? await Task.sleep(for: .seconds(2))
        }
        throw IbexError.timeout("No node reported")
    }

    /// Polls for url.txt until Jupyter reports its URL, the job dies, or we time out.
    private func waitForJupyter(job: Job, timeout: TimeInterval) async throws -> (port: Int, token: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = try? await slurmService.readJupyterSession(jobID: job.id) {
                return found
            }
            if await slurmService.sessionFailed(jobID: job.id) {
                throw IbexError.tunnelFailed("Jupyter could not start on the node. Check the output below.")
            }
            guard job.state.isActive else {
                throw IbexError.tunnelFailed("The job ended before Jupyter finished starting. Check the output below.")
            }
            let remaining = Int(deadline.timeIntervalSinceNow)
            job.setupStage = "Starting Jupyter on \(job.nodeName ?? "the node")… (\(max(remaining, 0))s left)"
            try? await Task.sleep(for: .seconds(3))
        }
        throw IbexError.timeout(
            "Jupyter did not report a URL within \(Int(timeout)) seconds. Check the output below."
        )
    }

    /// Keeps each job's tunnel flag in step with the tunnel processes, so a
    /// dropped tunnel surfaces a Reconnect button instead of a dead link.
    private func reconcileTunnels() {
        let lost = tunnelManager.healthCheck()
        for job in jobs where lost.contains(job.id) {
            job.tunnelActive = false
            job.localPort = nil
            if job.state == .running {
                job.tunnelError = "The tunnel dropped. Reconnect to get a new link."
            }
        }
    }

    /// Re-runs the Jupyter handshake for a job whose tunnel is missing.
    func ensureJupyterConnection(_ job: Job) {
        guard job.kind == .jupyter, job.state == .running, !job.tunnelActive else { return }
        startJupyterSetup(job)
    }

    // MARK: - Output streaming

    func syncStreamer() {
        guard let job = selectedJob, let path = job.outputPath else {
            if outputStreamer.jobID != nil { outputStreamer.detach() }
            return
        }
        outputStreamer.attach(jobID: job.id, remotePath: path)
    }

    // MARK: - Persistence

    private func loadRecords() -> [JobRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([JobRecord].self, from: data)
        else { return [] }
        return records
    }

    private func saveRecord(_ record: JobRecord) {
        var records = loadRecords().filter { $0.id != record.id }
        records.append(record)
        records = Array(records.suffix(25))
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    private func deleteRecord(id: String) {
        let records = loadRecords().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    // MARK: - Teardown

    /// Called when the app quits. Jobs keep running on the cluster on purpose —
    /// the app re-adopts them on the next launch.
    func onTerminate() {
        stopPolling()
        tunnelManager.destroyAllTunnels()
        outputStreamer.detach()
    }
}
