import Backup
import DesignSystem
import InkModel
import Library
import SwiftUI

/// Settings › Restore… (mock 03), pushed inside the popover: the folder's notebooks, each with Restore, or
/// Restore All. Notebooks already on this iPad are inert; a restored row shows a check and the notebook is in
/// the library behind at once. Deleted ones (the folder's `Trash/`) come back as live notebooks.
struct RestoreView: View {
    let backup: BackupModel

    var body: some View {
        Form {
            if let catalog = backup.catalog, !catalog.notebooks.isEmpty {
                let live = catalog.notebooks.filter { !$0.trashed }
                let deleted = catalog.notebooks.filter(\.trashed)
                if !live.isEmpty {
                    Section {
                        ForEach(live) { row($0, folders: catalog.folders) }
                    } header: {
                        Text("In \(backup.folderShortName) · \(EditedLabel.notebooks(live.count))")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } footer: {
                        Text(
                            """
                            Notebooks already on this iPad are skipped. Folders come back as they were. Restoring never \
                            changes what is on this iPad.
                            """
                        )
                    }
                }
                if !deleted.isEmpty {
                    Section {
                        ForEach(deleted) { row($0, folders: catalog.folders) }
                    } header: {
                        Text("Recently deleted")
                    }
                }
            } else {
                Section {
                    Text("No notebooks in this folder yet.")
                        .foregroundStyle(Tokens.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("Restore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Restore All") {
                    Task { await backup.restoreAll() }
                }
                .disabled(backup.restorableCount == 0)
                .accessibilityIdentifier("restoreAll")
            }
        }
        .task { await backup.loadCatalog() }
    }

    private func row(_ item: BackupCatalog.Notebook, folders: [LibraryFolder]) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            RoundedRectangle(cornerRadius: 4)
                .fill(item.cover.style.color)
                .frame(width: 26, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .scaledFont(size: 15.5, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                Text(subtitle(item, folders: folders))
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Spacing.s)
            trailing(item)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func trailing(_ item: BackupCatalog.Notebook) -> some View {
        switch backup.rowState(item) {
        case .restorable:
            Button("Restore") {
                Task { await backup.restore([item]) }
            }
            .scaledFont(size: 13.5, weight: .semibold)
            .foregroundStyle(Tokens.Colors.selection)
            .padding(.horizontal, Tokens.Spacing.m)
            .frame(minHeight: 28)
            .background(Tokens.Colors.dropTarget, in: .capsule)
            .buttonStyle(.plain)
            .accessibilityIdentifier("restore-\(item.title)")
        case .restoring:
            Text("Restoring…")
                .scaledFont(size: 13)
                .foregroundStyle(Tokens.Colors.textSecondary)
        case .restored:
            Image(systemName: "checkmark")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.green)
                .accessibilityLabel("Restored")
                .accessibilityIdentifier("restored-\(item.title)")
        case .onThisIPad:
            Text("On this iPad")
                .scaledFont(size: 13)
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
    }

    /// "11 pages · Physics · Yesterday".
    private func subtitle(_ item: BackupCatalog.Notebook, folders: [LibraryFolder]) -> String {
        let folder = item.folderID.flatMap { id in folders.first { $0.id == id }?.name }
        let date = EditedLabel.edited(item.modifiedAt).replacingOccurrences(of: "Edited ", with: "")
        return ([EditedLabel.pages(item.pageCount)] + [folder].compactMap(\.self) + [date]).joined(separator: " · ")
    }
}
