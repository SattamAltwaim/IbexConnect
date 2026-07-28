import Foundation

@Observable
final class SSHTunnel: Identifiable {
    let id: String
    let localPort: Int
    let remoteHost: String
    let remotePort: Int
    var process: Process?
    var isActive: Bool = false

    init(id: String, localPort: Int, remoteHost: String, remotePort: Int) {
        self.id = id
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}
