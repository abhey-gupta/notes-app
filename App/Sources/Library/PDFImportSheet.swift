import DesignSystem
import InkModel
import Library
import os
import SwiftUI

/// Import PDF (#119, UI agreed 2026-10-26): a centred card like the new-notebook sheet. Cancel · "Import
/// PDF" · dark Import pill; the first three pages and "+ N pages"; title (the file name) and folder
/// (the one open in the library); "24 pages · 3.1 MB". Import hands the draft back; the library writes
/// the notebook and opens it on page 1.
struct PDFImportSheet: View {
    let request: PDFImportRequest
    let library: any LibraryModel
    let onImport: (PDFImportDraft) -> Void

    @State private var title: String
    @State private var folderID: FolderID?
    @State private var preview: PDFImportPreview?
    @State private var isImporting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private static let shownPages = 3
    private static let thumbWidth: CGFloat = 104

    init(request: PDFImportRequest, folder: FolderID?, library: any LibraryModel, onImport: @escaping (PDFImportDraft) -> Void) {
        self.request = request
        self.library = library
        self.onImport = onImport
        _title = State(initialValue: request.suggestedTitle)
        _folderID = State(initialValue: folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            pages
                .padding(.top, 22)
            label("Title")
            titleField
            label("Folder")
            folderPicker
            footnote
                .padding(.top, 16)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .presentationSizing(.fitted)
        .task {
            preview = await PDFImportPreview.load(request.url, count: Self.shownPages, width: Self.thumbWidth, scale: displayScale)
        }
    }

    private var header: some View {
        ZStack {
            Text("Import PDF")
                .font(.chromeTitle)
                .foregroundStyle(Tokens.Colors.textPrimary)
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Import") {
                    isImporting = true
                    onImport(PDFImportDraft(url: request.url, title: title, folderID: folderID))
                }
                .buttonStyle(.glassProminent)
                .tint(Tokens.Colors.textPrimary.color)
                .foregroundStyle(Tokens.Colors.libraryBackground)
                .fontWeight(.semibold)
                .keyboardShortcut(.defaultAction)
                .disabled(preview?.problem != nil || isImporting)
                .accessibilityIdentifier("importPDF")
            }
        }
    }

    /// The first pages on the sheet's inset panel, at the notebook's page proportions.
    private var pages: some View {
        let size = preview?.pageSize ?? Notebook.a4Portrait
        let thumb = CGSize(width: Self.thumbWidth, height: (Self.thumbWidth * size.height / size.width).rounded())
        let shown = preview.map { min($0.pageCount, Self.shownPages) } ?? Self.shownPages
        return HStack(spacing: Tokens.Spacing.xl) {
            ForEach(0 ..< max(shown, 1), id: \.self) { index in
                pageThumb(index, size: thumb)
            }
            if let preview, preview.pageCount > Self.shownPages {
                Text("+ \(preview.pageCount - Self.shownPages) pages")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .fixedSize()
                    .padding(.leading, Tokens.Spacing.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.xxl)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Colors.sheetPanel, in: .rect(cornerRadius: Tokens.Radius.preview, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.map { "\($0.pageCount) pages" } ?? "Pages")
    }

    /// White paper until the page renders (no spinner), then the page.
    private func pageThumb(_ index: Int, size: CGSize) -> some View {
        let image = preview.flatMap { index < $0.thumbnails.count ? $0.thumbnails[index] : nil }
        return RoundedRectangle(cornerRadius: Tokens.Radius.page, style: .continuous)
            .fill(Color.white)
            .overlay {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .clipShape(.rect(cornerRadius: Tokens.Radius.page, style: .continuous))
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(Tokens.Shadows.pageContact)
            .shadow(Tokens.Shadows.thumb)
            .animation(Tokens.Motion.thumbnailCrossfade, value: image != nil)
    }

    private var titleField: some View {
        TextField("Untitled", text: $title)
            .font(.notebookTitle(size: 19))
            .foregroundStyle(Tokens.Colors.textPrimary)
            .tint(Tokens.Colors.selection.color)
            .submitLabel(.done)
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.vertical, 12)
            .background(Tokens.Colors.field, in: .rect(cornerRadius: Tokens.Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.field).strokeBorder(Tokens.Colors.fieldBorder, lineWidth: 0.5)
            }
            .accessibilityIdentifier("pdfTitle")
    }

    private var folderPicker: some View {
        Menu {
            folderButton("None", id: nil)
            ForEach(library.folders) { folder in
                folderButton(folder.name, id: folder.id)
            }
        } label: {
            let folderName = library.folder(id: folderID)?.name
            HStack(spacing: Tokens.Spacing.m) {
                Image(systemName: folderName == nil ? "tray.full" : "folder")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(width: 22)
                Text(folderName ?? "None")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textTertiary)
            }
            .padding(.horizontal, Tokens.Spacing.l)
            .frame(minHeight: 46)
            .background(Tokens.Colors.field, in: .rect(cornerRadius: Tokens.Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.field).strokeBorder(Tokens.Colors.fieldBorder, lineWidth: 0.5)
            }
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Folder")
        .accessibilityValue(library.folder(id: folderID)?.name ?? "None")
        .accessibilityIdentifier("pdfFolder")
    }

    private func folderButton(_ name: String, id: FolderID?) -> some View {
        Button {
            folderID = id
        } label: {
            if folderID == id {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        switch preview?.problem {
        case .locked:
            problem("This PDF is password-protected.")
        case .unreadable:
            problem("This file can't be opened as a PDF.")
        case nil:
            Text(preview?.summary ?? " ")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .accessibilityIdentifier("pdfSummary")
        }
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(Tokens.Colors.textSecondary)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11.5, weight: .semibold)
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .padding(.top, 22)
            .padding(.bottom, 10)
    }
}

extension View {
    /// Presents the import sheet for `request`; Import writes the notebook (package + index entry, then
    /// `onImported` opens it on page 1, like Create, §8). Staged files are deleted when the sheet goes.
    func pdfImport(
        _ request: Binding<PDFImportRequest?>,
        folder: FolderID?,
        library: any LibraryModel,
        onImported: @escaping (NotebookSummary) -> Void
    ) -> some View {
        sheet(item: request, onDismiss: PDFInbox.discardAll) { pending in
            PDFImportSheet(request: pending, folder: folder, library: library) { draft in
                OpenTrace.beginCreate()
                Task {
                    do {
                        let notebook = try await library.importPDF(draft)
                        request.wrappedValue = nil
                        onImported(notebook)
                    } catch {
                        OpenTrace.cancel()
                        request.wrappedValue = nil
                        Logger(subsystem: "com.abhey.notespace", category: "library")
                            .error("import PDF: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
}
