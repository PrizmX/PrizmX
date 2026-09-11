import SwiftUI

/// Popover for the External IP tag. Geo/ISP come from ipwho.is (HTTPS, no key).
struct ExternalIPPopover: View {
    @Environment(AppModel.self) private var appModel
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("External IP")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh")
            }
            HStack(spacing: 6) {
                if let flag = appModel.egressInfo?.flagEmoji {
                    Text(flag)
                }
                Text(appModel.egressIP)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .textSelection(.enabled)
            }
            if let info = appModel.egressInfo {
                detailRow("Location", locationLine(info))
                if let org = info.org, !org.isEmpty {
                    detailRow("Network", org)
                }
                detailRow("Updated", info.fetchedAt.formatted(date: .omitted, time: .shortened))
            } else if let error = appModel.egressLookupError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Looking up location…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("IP from ipify.org · details from ipwho.is")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .task { await refresh() }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }

    private func locationLine(_ info: EgressIPInfo) -> String {
        let parts = [info.city, info.region, info.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await appModel.refreshEgress()
    }
}
