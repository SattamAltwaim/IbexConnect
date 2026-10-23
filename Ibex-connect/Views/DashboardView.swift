import SwiftUI

struct DashboardView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var showingNewJob = false
    @State private var showingTransfer = false
    @State private var isOutputVisible = false

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    GPUAvailabilityView()

                    JobListView { job in
                        vm.selectedJobID = job.id
                        vm.syncStreamer()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isOutputVisible = true
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isOutputVisible {
                LogPanelView {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isOutputVisible = false
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ConnectionStatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: vm.selectedJobID) { _, newValue in
            if newValue != nil, !isOutputVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOutputVisible = true
                }
            }
        }
        .sheet(isPresented: $showingNewJob) {
            NewJobSheet()
        }
        .sheet(isPresented: $showingTransfer) {
            FileTransferSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { vm.error != nil },
                set: { if !$0 { vm.error = nil } }
            ),
            presenting: vm.error
        ) { _ in
            Button("OK") { vm.error = nil }
        } message: { error in
            Text(error.localizedDescription)
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ibex Connect")
                    .font(.system(size: 28, weight: .bold))
                Text("GPU jobs on KAUST's Ibex cluster")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    Task { await vm.signOut() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Sign out of \(vm.username) and go back to the login window. Jobs keep running on the cluster.")

                Button {
                    Task { await vm.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("r")
                .help("Refresh GPU availability and job states (⌘R)")

                Button {
                    showingTransfer = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.doc")
                        Text("Upload Files")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("u")
                .disabled(vm.connection != .connected)
                .help("Copy files or folders from this Mac to Ibex (⌘U)")

                Button {
                    showingNewJob = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New Job")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n")
                .disabled(vm.connection != .connected)
                .help("Start a Jupyter session or submit a batch job (⌘N)")
            }
        }
        .padding(.bottom, 4)
    }
}
