import SwiftUI
import AppKit

// MARK: - Performant log view (AppKit-backed, same approach as RaBit)

struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor.secondaryLabelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        guard text != textView.string else { return }

        // Stick to the bottom only if the user hasn't scrolled up to read.
        let wasAtBottom: Bool = {
            let clipView = nsView.contentView
            let docH = nsView.documentView?.frame.height ?? 0
            let visH = clipView.bounds.height
            return clipView.bounds.origin.y + visH >= docH - 40
        }()

        textView.string = text

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

// MARK: - Bottom output panel

struct LogPanelView: View {
    @Environment(AppViewModel.self) private var vm
    let onClose: () -> Void

    @State private var logPanelHeight: CGFloat = 220
    @GestureState private var dragOffset: CGFloat = 0

    private var effectiveHeight: CGFloat {
        max(100, min(500, logPanelHeight - dragOffset))
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            dragHandle

            HStack(spacing: 10) {
                Text("JOB OUTPUT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(1)

                if let job = vm.selectedJob {
                    HStack(spacing: 6) {
                        Text("#\(job.id)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(job.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(job.state.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(job.stateColor)
                    }
                }

                Spacer()

                if !vm.outputStreamer.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.outputStreamer.text, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy Output")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the captured output to the clipboard")
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide the output panel")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            content
        }
        .frame(height: effectiveHeight)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var content: some View {
        if vm.selectedJob == nil {
            placeholder("Select a job above to watch its output here.")
        } else if vm.selectedJob?.outputPath == nil {
            placeholder("Slurm hasn't reported an output file for this job.")
        } else if vm.outputStreamer.text.isEmpty {
            placeholder(
                vm.selectedJob?.state == .pending
                    ? "The job is still queued — output will appear as soon as it starts."
                    : "No output yet."
            )
        } else {
            LogTextView(text: vm.outputStreamer.text)
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dragHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 36, height: 4)
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        logPanelHeight = max(100, min(500, logPanelHeight - value.translation.height))
                    }
            )
    }
}
