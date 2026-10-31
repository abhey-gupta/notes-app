import DesignSystem
import SwiftUI

/// Under the library title while a backup copies or uploads (mock 05-D): "Backing up Thermodynamics · 3 of 14"
/// in caption grey with a 120 pt hairline, then "Backed up just now" for 2 s, then it folds away. Nothing
/// when idle or off.
struct BackupStatusLine: View {
    @Environment(BackupModel.self) private var backup: BackupModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = backup?.line {
                HStack(spacing: 10) {
                    Text(text(line))
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                    if case let .progress(_, fraction) = line {
                        Hairline(fraction: fraction)
                            .frame(width: 120)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("backupStatus")
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0), value: backup?.line == nil)
    }

    private func text(_ line: BackupModel.Line) -> String {
        switch line {
        case let .progress(text, _): text
        case .done: "Backed up just now"
        }
    }
}

/// Fresh iPad (mock 04): the library is empty and the backup folder lists notebooks. "Restore all" brings them
/// back with their folders; "Choose…" opens Settings on Restore. Gone once the library has a notebook.
struct RestoreCard: View {
    let backup: BackupModel
    let count: Int

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "icloud.and.arrow.down")
                .scaledFont(size: 30, weight: .regular)
                .foregroundStyle(Tokens.Colors.pillText)
                .accessibilityHidden(true)
            Text("\(EditedLabel.notebooks(count)) in \(backup.folderShortName)")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .padding(.top, 6)
            if let catalog = backup.catalog {
                Text("Backed up from \(catalog.device), \(BackupSettingsSection.ago(catalog.writtenAt, now: Date())).")
                    .scaledFont(size: 14)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button("Restore all") {
                    Task { await backup.restoreAll() }
                }
                .foregroundStyle(Tokens.Colors.libraryBackground)
                .padding(.horizontal, Tokens.Spacing.xl)
                .frame(minHeight: 40)
                .background(Tokens.Colors.textPrimary, in: .capsule)
                .accessibilityIdentifier("restoreAllCard")
                Button("Choose…") { backup.opensRestore = true }
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .padding(.horizontal, Tokens.Spacing.xl)
                    .frame(minHeight: 40)
                    .background(Tokens.Colors.subtleFill, in: .capsule)
                    .accessibilityIdentifier("chooseRestore")
            }
            .scaledFont(size: 14.5, weight: .semibold)
            .buttonStyle(.plain)
            .padding(.top, Tokens.Spacing.s)
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("restoreCard")
    }
}
