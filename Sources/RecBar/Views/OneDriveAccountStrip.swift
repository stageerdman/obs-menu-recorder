import SwiftUI

/// One-line OneDrive status under the Library header: who's signed in, how much space is left,
/// and the single next action for whatever state the connection is in (Connect / Retry / an
/// account menu). Exists because sign-in used to be invisible — triggered only implicitly by
/// the first upload — so there was no way to see the account, its storage, or reconnect.
struct OneDriveAccountStrip: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(spacing: 8) {
            glyph.frame(width: 16)
            Text(message)
                .font(.callout)
                .foregroundStyle(messageStyle)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(helpText)
            if let info = driveInfo, info.totalBytes > 0 {
                ProgressView(value: Double(info.usedBytes), total: Double(info.totalBytes))
                    .tint(quotaColor(info) ?? .accentColor)
                    .frame(width: 60)
                    .accessibilityLabel("Storage used")
                    .accessibilityValue("\(Int(Double(info.usedBytes) / Double(info.totalBytes) * 100)) percent used")
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }

    private var driveInfo: OneDriveClient.DriveInfo? {
        switch viewModel.accountStatus {
        case .connected(let info): return info
        default: return nil
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch viewModel.accountStatus {
        case .notConfigured, .signedOut:
            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
        case .signingIn, .loading:
            ProgressView().controlSize(.small)
        case .connected(let info):
            if let color = quotaColor(info), info.quotaState != "nearing" {
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(color)
            } else {
                Image(systemName: "icloud.fill").foregroundStyle(quotaColor(info) ?? .accentColor)
            }
        case .unreachable:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
        }
    }

    private var message: String {
        switch viewModel.accountStatus {
        case .notConfigured:
            return "OneDrive not set up — add oneDrive.clientId to config.json"
        case .signedOut(let expired):
            return expired ? "OneDrive sign-in expired" : "Not connected to OneDrive"
        case .signingIn:
            return "Waiting for Microsoft sign-in…"
        case .loading:
            return "Loading OneDrive account…"
        case .connected(let info):
            let name = info.ownerName ?? "OneDrive"
            if info.totalBytes <= 0 { return name }
            let free = Self.bytes(max(info.totalBytes - info.usedBytes, 0))
            switch info.quotaState {
            case "exceeded": return "\(name) · OneDrive full — uploads will fail"
            case "critical": return "\(name) · \(free) free · uploads may fail"
            case "nearing":  return "\(name) · \(free) free of \(Self.bytes(info.totalBytes)) · almost full"
            default:         return "\(name) · \(free) free of \(Self.bytes(info.totalBytes))"
            }
        case .unreachable(let last):
            guard let last, last.totalBytes > 0 else { return "Can't reach OneDrive" }
            return "Can't reach OneDrive · last seen \(Self.bytes(max(last.totalBytes - last.usedBytes, 0))) free"
        }
    }

    private var messageStyle: HierarchicalShapeStyle {
        if case .connected = viewModel.accountStatus { return .primary }
        return .secondary
    }

    private var helpText: String {
        if case .connected = viewModel.accountStatus { return "Signed in to personal OneDrive" }
        return ""
    }

    @ViewBuilder
    private var trailing: some View {
        switch viewModel.accountStatus {
        case .notConfigured, .loading:
            EmptyView()
        case .signedOut:
            Button("Connect") { viewModel.connect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .signingIn:
            Button("Cancel") { viewModel.cancelSignIn() }
                .controlSize(.small)
        case .unreachable:
            Button { viewModel.refreshAccount() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Retry")
                .accessibilityLabel("Retry")
        case .connected:
            Menu {
                Button("Reload") { viewModel.refreshAccount() }
                Button("Switch Account…") { viewModel.switchAccount() }
                Divider()
                Button("Sign Out") { viewModel.signOut() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)  // same overlapping-chevron issue as RecordingRow's menu
            .frame(width: 24)
            .accessibilityLabel("Account options")
        }
    }

    /// Orange when nearing full, red when critical/exceeded, nil (default accent) otherwise —
    /// color only ever signals storage trouble.
    private func quotaColor(_ info: OneDriveClient.DriveInfo) -> Color? {
        switch info.quotaState {
        case "nearing": return .orange
        case "critical", "exceeded": return RecBarColor.red
        default: return nil
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
