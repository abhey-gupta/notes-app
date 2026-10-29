import DesignSystem
import Library
import SwiftUI

/// Compact library's folders (#118): full screen from the sidebar button, one row per folder under All
/// Notebooks. Picking a row filters the library and closes the sheet; ✕ closes it as it was.
struct FoldersSheet: View {
    let library: any LibraryModel
    @Binding var folder: FolderID?

    @State private var prompt: LibraryPrompt?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chromeLayout) private var chrome

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row("All Notebooks", systemImage: "books.vertical", count: library.notebooks(in: nil, matching: "").count, id: nil)
                ForEach(library.folders) { item in
                    row(item.name, systemImage: "folder", count: count(in: item.id), id: item.id)
                        .contextMenu {
                            Button("Rename Folder", systemImage: "pencil") { prompt = .renameFolder(item) }
                            Button("Delete Folder", systemImage: "trash", role: .destructive) {
                                if folder == item.id {
                                    folder = nil
                                }
                                library.deleteFolder(item.id)
                            }
                        }
                }
                Button {
                    prompt = .newFolder
                } label: {
                    Label("New Folder", systemImage: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                        .padding(.horizontal, Tokens.Spacing.l)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newFolder")
            }
            .padding(.horizontal, chrome.margin - Tokens.Spacing.l)
            .padding(.vertical, Tokens.Spacing.s)
        }
        .background { Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea() }
        .safeAreaBar(edge: .top) { header }
        .libraryPrompts($prompt, library: library)
        .accessibilityIdentifier("foldersSheet")
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Text("Folders")
                .font(.libraryTitle)
                .tracking(-0.5)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Tokens.Spacing.m)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.pillText)
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")
        }
        .padding(.leading, chrome.margin + chrome.windowControls.leading)
        .padding(.trailing, chrome.margin - 4)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private func row(_ name: String, systemImage: String, count: Int, id: FolderID?) -> some View {
        let selected = folder == id
        return Button {
            folder = id
            dismiss()
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Image(systemName: systemImage)
                    .scaledFont(size: 17, weight: .regular)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(width: 28)
                Text(name)
                    .scaledFont(size: 16, weight: selected ? .semibold : .regular)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Spacing.m)
                Text("\(count)")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Tokens.Spacing.l)
            .frame(minHeight: 48)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Tokens.Radius.field, style: .continuous)
                        .fill(Tokens.Colors.subtleFill)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(EditedLabel.notebooks(count))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("folder-\(name)")
    }

    private func count(in id: FolderID) -> Int {
        library.notebooks(in: id, matching: "").count
    }
}

extension EditedLabel {
    static func notebooks(_ count: Int) -> String {
        count == 1 ? "1 notebook" : "\(count) notebooks"
    }
}
