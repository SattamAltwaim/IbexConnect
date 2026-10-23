import Foundation
import Security
import Synchronization

nonisolated enum AuthMethod: String, CaseIterable, Sendable {
    /// The KAUST password, handed to ssh through an askpass helper.
    case password
    /// A key registered on Ibex; ssh runs in batch mode and never prompts.
    case key
}

/// The password of the signed-in session, in memory only. Every ssh the app
/// spawns reads it from here; the Keychain is what keeps it between launches.
nonisolated enum SessionPassword {
    private static let storage = Mutex<String?>(nil)

    static var current: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// The user's Keychain, which holds the password at rest when they asked
/// the app to remember it.
nonisolated enum Keychain {
    private static let service = "IbexConnect"

    private static func query(for user: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
        ]
    }

    static func savePassword(_ password: String, for user: String) {
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query(for: user) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: user)
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func password(for user: String) -> String? {
        var item = query(for: user)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for user: String) {
        SecItemDelete(query(for: user) as CFDictionary)
    }
}

/// ssh only takes a password from a terminal or from an askpass program.
/// The app has no terminal, so it installs a tiny script that prints the
/// password from an environment variable, and points ssh at it.
nonisolated enum AskpassHelper {
    static let passwordVariable = "IBEXCONNECT_SSH_PASSWORD"

    /// Installed on first use; nil when Application Support can't be written.
    static let path: String? = install()

    private static func install() -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = support.appending(path: "IbexConnect")
        let file = directory.appending(path: "askpass.sh")
        let script = """
            #!/bin/sh
            # Written by IbexConnect. ssh runs this to get the session password.
            printf '%s\\n' "$\(passwordVariable)"

            """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != script {
                try script.write(to: file, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }
}
