import AppKit
import SwiftUI

/// Shown until the app has signed in to Ibex. Sign-in is key-based: the
/// window takes a KAUST username and the key registered for it, and on
/// failure explains what to fix (VPN, missing or unregistered key, …).
struct LoginView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var username = ""
    @State private var keyPath = ClusterConfig.defaultKeyPath
    @FocusState private var usernameFocused: Bool

    private var isConnecting: Bool { vm.connection == .connecting }
    private var canConnect: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !keyPath.isEmpty && !isConnecting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                form
                if isConnecting {
                    connecting
                } else if let failure = vm.loginFailure {
                    FailureCard(failure: failure)
                }
                footer
            }
            .frame(width: 440)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .onAppear {
            username = vm.username
            keyPath = vm.savedKeyPath
            usernameFocused = username.isEmpty
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ibex Connect")
                .font(.system(size: 28, weight: .bold))
            Text("Sign in to KAUST's Ibex cluster")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                label("KAUST USERNAME")
                field(TextField("", text: $username, prompt: Text("username")))
                    .focused($usernameFocused)
                    .disabled(isConnecting)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("SSH KEY")
                HStack(spacing: 8) {
                    field(TextField("", text: $keyPath, prompt: Text(ClusterConfig.defaultKeyPath)))
                        .disabled(isConnecting)

                    Button("Browse") { chooseKey() }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .disabled(isConnecting)
                }
                Text("The private key registered on Ibex for this account. The app never asks for a password.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await vm.signIn(user: username, keyPath: keyPath) }
            } label: {
                HStack(spacing: 6) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(nsColor: .windowBackgroundColor))
                    }
                    Text(isConnecting ? "Connecting…" : "Connect")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(canConnect ? 1 : 0.4))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect)
        }
    }

    private var connecting: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
            Text("Connecting to \(vm.loginNode)…")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("Ibex only accepts connections from inside KAUST. Off campus, connect to the KAUST VPN first.")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }

    private func field(_ textField: TextField<Text>) -> some View {
        textField
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // ~/.ssh is hidden, which is where the key almost always lives.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh")
        panel.message = "Choose the private key registered on Ibex (not the .pub file)"
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path(percentEncoded: false)
        }
    }
}

private struct FailureCard: View {
    let failure: LoginFailure

    @State private var copiedCommand: String?
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(failure.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if failure.kind == .vpn {
                Button(Self.ciscoClient == nil ? "Open VPN Settings" : "Open Cisco Secure Client") {
                    openVPNClient()
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 30)
            }

            ForEach(failure.commands) { command in
                VStack(alignment: .leading, spacing: 4) {
                    Text(command.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        Text(command.command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(copiedCommand == command.command ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command.command, forType: .string)
                            copiedCommand = command.command
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.leading, 30)
            }

            if let detail = failure.detail, !detail.isEmpty {
                DisclosureGroup("ssh output", isExpanded: $showDetail) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 30)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var icon: String {
        switch failure.kind {
        case .vpn: "lock.shield"
        case .offline: "wifi.slash"
        case .keyMissing, .keyRejected: "key"
        case .hostKeyChanged: "exclamationmark.shield"
        case .other: "exclamationmark.triangle"
        }
    }

    /// KAUST's VPN client, when it is installed.
    private static let ciscoClient: URL? = {
        let url = URL(fileURLWithPath: "/Applications/Cisco/Cisco Secure Client.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// The Cisco client if present, else System Settings' VPN pane, else
    /// System Settings itself on a release that doesn't know the pane.
    private func openVPNClient() {
        if let cisco = Self.ciscoClient {
            NSWorkspace.shared.openApplication(at: cisco, configuration: .init())
            return
        }
        let pane = URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
