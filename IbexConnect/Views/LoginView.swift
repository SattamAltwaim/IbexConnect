import AppKit
import SwiftUI

/// Shown until the app has signed in to Ibex. Sign-in is key-based: the
/// window takes a KAUST username and the key registered for it, and on
/// failure explains what to fix (VPN, missing or unregistered key, …).
struct LoginView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var username = ""
    @State private var method: AuthMethod = .password
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var keyPath = ClusterConfig.defaultKeyPath
    @FocusState private var usernameFocused: Bool

    private var isConnecting: Bool { vm.connection == .connecting }
    private var canConnect: Bool {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !isConnecting else { return false }
        switch method {
        case .password: return !password.isEmpty
        case .key: return !keyPath.isEmpty
        }
    }

    private func signIn() {
        guard canConnect else { return }
        Task {
            switch method {
            case .password:
                await vm.signIn(user: username, password: password, remember: rememberPassword)
            case .key:
                await vm.signIn(user: username, keyPath: keyPath)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            LogoMorphView(columns: 56, rows: 24, fontSize: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.03))

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
                .padding(.horizontal, 40)
                .padding(.vertical, 48)
            }
            .frame(width: 480)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .onAppear {
            username = vm.username
            method = vm.authMethod
            keyPath = vm.savedKeyPath
            usernameFocused = username.isEmpty
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("IbexConnect")
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
                    .onSubmit(signIn)
                    .disabled(isConnecting)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("SIGN IN WITH")
                MethodSwitch(selection: $method)
                    .disabled(isConnecting)
                    .help("Password: your KAUST password, kept in your Keychain if you ask. "
                        + "SSH key: a key registered on Ibex, so nothing is ever typed again.")
            }

            switch method {
            case .password:
                VStack(alignment: .leading, spacing: 6) {
                    label("KAUST PASSWORD")
                    field(SecureField("", text: $password, prompt: Text("password")))
                        .onSubmit(signIn)
                        .disabled(isConnecting)
                    Toggle("Remember in my Keychain", isOn: $rememberPassword)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .disabled(isConnecting)
                        .help("Saved in the macOS Keychain, so the app signs in by itself next time. "
                            + "Sign out to forget it.")
                }
            case .key:
                VStack(alignment: .leading, spacing: 6) {
                    label("SSH KEY")
                    HStack(spacing: 8) {
                        field(TextField("", text: $keyPath, prompt: Text(ClusterConfig.defaultKeyPath)))
                            .onSubmit(signIn)
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
                    HStack(spacing: 4) {
                        Text("Don't have a key?")
                            .foregroundStyle(.tertiary)
                        KeyHelpLink(loginNode: vm.loginNode)
                    }
                    .font(.system(size: 11))
                }
            }

            Button {
                signIn()
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

    private func field(_ textField: some View) -> some View {
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

/// Password / SSH key, drawn like the rest of the window's controls rather
/// than as the system's blue segmented control.
private struct MethodSwitch: View {
    @Binding var selection: AuthMethod

    var body: some View {
        HStack(spacing: 2) {
            segment("Password", icon: "lock", .password)
            segment("SSH key", icon: "key", .key)
        }
        .padding(2)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func segment(_ title: String, icon: String, _ method: AuthMethod) -> some View {
        let selected = selection == method
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = method
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? Color.primary : Color.clear)
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The "How to make one" link under the key field: a popover with the two
/// commands, so they can be copied.
private struct KeyHelpLink: View {
    let loginNode: String

    @State private var isShown = false
    @State private var copied: String?

    var body: some View {
        Button("How to make one") {
            isShown.toggle()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Don't have a key yet?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Run these two commands in Terminal. The second asks for your KAUST password once; "
                    + "after that the key signs you in and the app never needs the password.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                command("1. Create a key", "ssh-keygen -t ed25519")
                command("2. Register it on Ibex (replace USERNAME)", "ssh-copy-id USERNAME@\(loginNode)")

                Text("Then choose ~/.ssh/id_ed25519 in the field and connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 380)
        }
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button(copied == text ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = text
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
        case .passwordRejected: "lock"
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
