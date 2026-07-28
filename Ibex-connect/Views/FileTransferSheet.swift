import SwiftUI
import UniformTypeIdentifiers

struct FileTransferSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var localPath = ""
    @State private var remotePath = "/home/tuuaimss/"
    @State private var showFilePicker = false
    @State private var isTransferring = false
    @State private var isDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upload to Ibex")
                    .font(.system(size: 22, weight: .bold))
                Text("Copies a file or folder from this Mac to your home on the cluster.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Local path
            VStack(alignment: .leading, spacing: 6) {
                Text("FILE OR FOLDER ON THIS MAC")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)

                HStack(spacing: 8) {
                    TextField("", text: $localPath, prompt: Text("/path/to/file"))
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

                    Button("Browse") {
                        showFilePicker = true
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            // Remote path
            VStack(alignment: .leading, spacing: 6) {
                Text("DESTINATION ON IBEX")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)

                TextField("", text: $remotePath)
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

            Spacer()

            // Status
            if isTransferring {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Uploading… this can take a while for large folders")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if isDone {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Upload complete")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    transfer()
                } label: {
                    Text("Upload")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(localPath.isEmpty ? Color.primary.opacity(0.3) : Color.primary)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(localPath.isEmpty || isTransferring)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 350)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                localPath = url.path(percentEncoded: false)
            }
        }
    }

    private func transfer() {
        isTransferring = true
        isDone = false
        Task {
            do {
                try await vm.transferService.transferFile(
                    localPath: localPath,
                    remotePath: remotePath
                )
                isDone = true
            } catch {
                vm.error = .transferFailed(error.localizedDescription)
            }
            isTransferring = false
        }
    }
}
