import AppKit
import SwiftUI
import PrizmXServices

/// Tunnel runtime events (App Group `logs/tunnel.log`), oldest first.
/// Per-flow request data belongs to the Inspector, not this log.
struct EventsSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Populated by the first `refresh()` — reading the log synchronously here
    // would block the main actor while the sheet opens.
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Events")
                    .font(.headline)
                Text("Tunnel runtime log. Request-level data will appear in the Inspector.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("No events yet.")
                                .foregroundStyle(.tertiary)
                                .id("empty")
                        } else {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: lines.count) {
                    scrollToLatest(proxy)
                }
                .onAppear {
                    scrollToLatest(proxy, animated: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: 640, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetActionBar(onDone: { dismiss() }) {
                Button("Show in Finder") {
                    if let url = TunnelLog.fileURL() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bordered)
                Button("Clear") {
                    TunnelLog.clear()
                    Task { await refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(lines.isEmpty)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            }
        }
    }

    private nonisolated static func readLines() -> [String] {
        TunnelLog.read().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// `TunnelLog.read()` blocks on file I/O; keep it off the main actor.
    private func refresh() async {
        let next = await Task.detached(priority: .utility) { Self.readLines() }.value
        guard next != lines else { return }
        lines = next
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = lines.indices.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[error]") { return .red }
        if line.contains("[warn]") { return .orange }
        if line.contains("[debug]") { return .secondary }
        return .primary
    }
}

#Preview("Events") {
    EventsSheet()
}
