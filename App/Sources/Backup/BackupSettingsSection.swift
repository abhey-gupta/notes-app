import Backup
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup (mocks 01, 02, 06): before a folder, one blue "Choose Backup Folder…" row; after, the
/// folder (Change Folder… / Stop Backing Up), a progress row while copying, Back Up Now, Restore…. The footer
/// says how it stands.
struct BackupSettingsSection: View {
    let backup: BackupModel

    @State private var picksFolder = false

    var body: some View {
        Section {
            if let name = backup.folderName {
                folderRow(name)
                if case let .copying(progress) = backup.status {
                    progressRow(progress)
                }
                Button("Back Up Now") { backup.runNow() }
                    .disabled(backup.isCopying)
                    .accessibilityIdentifier("backUpNow")
                NavigationLink("Restore…", value: SettingsRoute.restore)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .accessibilityIdentifier("restoreBackup")
            } else {
                Button("Choose Backup Folder…") { picksFolder = true }
                    .accessibilityIdentifier("chooseBackupFolder")
            }
        } header: {
            Text("Backup")
        } footer: {
            // Ticks so "2 minutes ago" stays true while Settings is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(footer(now: context.date))
                    .accessibilityIdentifier("backupFooter")
            }
        }
        .fileImporter(isPresented: $picksFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                backup.choose(url)
            }
        }
    }

    private func folderRow(_ name: String) -> some View {
        Menu {
            Button("Change Folder…", systemImage: "folder") { picksFolder = true }
            Button("Stop Backing Up", systemImage: "xmark.circle", role: .destructive) { backup.stop() }
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Text("Backup folder")
                    .foregroundStyle(Tokens.Colors.textPrimary)
                Spacer(minLength: Tokens.Spacing.m)
                Text(name)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .accessibilityLabel("Backup folder")
        .accessibilityValue(name)
        .accessibilityIdentifier("backupFolder")
    }

    private func progressRow(_ progress: BackupEngine.Progress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Backing up \(progress.title)…")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
            Text(
                "\(progress.done + 1) of \(EditedLabel.notebooks(progress.total)) · \(progress.bytesLeft.formatted(.byteCount(style: .file))) left"
            )
            .scaledFont(size: 13)
            .foregroundStyle(Tokens.Colors.textSecondary)
            Hairline(fraction: Double(progress.done) / Double(max(progress.total, 1)), height: 3)
                .padding(.top, 5)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("backupProgress")
    }

    private func footer(now: Date) -> String {
        switch backup.status {
        case .off:
            """
            Pick a folder in Files — iCloud Drive, Google Drive, Dropbox… Notebooks are copied there as you write, so a new \
            iPad can pick up where this one left off.
            """
        case let .idle(summary):
            if let last = summary.last {
                "Up to date. Last backup \(Self.ago(last, now: now)) · \(EditedLabel.notebooks(summary.notebooks)), "
                    + "\(summary.bytes.formatted(.byteCount(style: .file)))."
            } else {
                "Notebooks are copied here as you write."
            }
        case .copying:
            "Only pages you changed are copied. Writing is never interrupted."
        case let .uploading(pending):
            "Copied. iCloud Drive is still uploading \(EditedLabel.notebooks(pending)). Files are safe on this iPad meanwhile."
        case .folderUnavailable:
            "The backup folder was moved or deleted. Choose it again to continue."
        case let .failed(message):
            message
        }
    }

    /// "just now", "2 minutes ago", "yesterday".
    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
    }
}

/// Settings popover pushes (inside its `NavigationStack`).
enum SettingsRoute: Hashable {
    case restore
}

/// A thin determinate bar: track and blue fill, rounded (no spinners, §1.4).
struct Hairline: View {
    var fraction: Double
    var height: CGFloat = 2

    var body: some View {
        Capsule()
            .fill(Tokens.Colors.separator)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Tokens.Colors.selection)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .clipShape(.capsule)
            .frame(height: height)
            .animation(.easeOut(duration: 0.25), value: fraction)
            .accessibilityHidden(true)
    }
}
