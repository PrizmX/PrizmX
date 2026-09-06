import AppKit
import SwiftUI
import PrizmXServices

/// Tunnel runtime events (App Group `logs/tunnel.log`), oldest first.
/// Per-flow request data belongs to the Inspector, not this log.
struct EventsSheet: View {
    @Environment(\.dismiss) private var dismiss
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
                    scrollToLatest(proxy)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            )

        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
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
                    refresh()
                }
                .buttonStyle(.bordered)
                .disabled(lines.isEmpty)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refresh()
            }
        }
    }

    private func refresh() {
        let text = TunnelLog.read()
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = lines.indices.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
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
