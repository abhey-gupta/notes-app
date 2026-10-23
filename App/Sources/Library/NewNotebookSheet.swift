import DesignSystem
import InkModel
import SwiftUI

/// New notebook (mock §06): title, cover, paper template, paper style. A4 portrait fixed.
/// Create hands the draft back; the library creates it and opens page 1 in the same step (§8).
struct NewNotebookSheet: View {
    let folder: LibraryFolder?
    let onCreate: (NotebookDraft) -> Void

    @State private var draft = NotebookDraft()
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            preview
            form
        }
        .frame(width: 720, height: 470)
        .presentationSizing(.fitted)
        .onAppear {
            draft.folderID = folder?.id
            titleFocused = true
        }
    }

    private var preview: some View {
        ZStack {
            // Inset card, concentric with the sheet's corners (the system sheet keeps a margin around content).
            ContainerRelativeShape().fill(Tokens.Colors.sheetPanel)
            NotebookCover(
                title: draft.title.isEmpty ? "Untitled" : draft.title,
                caption: folder?.name,
                color: draft.cover.style,
                width: 180
            )
            .rotationEffect(.degrees(-3))
            .animation(.snappy, value: draft.cover)
        }
        .frame(width: 290)
        .containerShape(.rect(cornerRadius: Tokens.Radius.sheet - 8, style: .continuous))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Text("New notebook")
                    .font(.chromeTitle)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Create") { onCreate(draft) }
                        .buttonStyle(.glassProminent)
                        .tint(Tokens.Colors.selection.color)
                        .fontWeight(.semibold)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("createNotebook")
                }
            }

            TextField("Untitled", text: $draft.title)
                .font(.notebookTitle(size: 19))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .tint(Tokens.Colors.selection.color)
                .focused($titleFocused)
                .submitLabel(.done)
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.vertical, 12)
                .background(Tokens.Colors.field, in: .rect(cornerRadius: Tokens.Radius.field))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.field).strokeBorder(Tokens.Colors.fieldBorder, lineWidth: 0.5)
                }
                .padding(.top, 22)
                .accessibilityIdentifier("notebookTitle")

            label("Cover")
            HStack(spacing: 2) {
                ForEach(InkModel.CoverColor.allCases, id: \.self) { cover in
                    ColorSwatch(cover.style.color, label: cover.rawValue.capitalized, isSelected: draft.cover == cover, diameter: 30) {
                        draft.cover = cover
                    }
                }
            }
            .padding(.horizontal, -4)

            label("Paper")
            HStack(spacing: 12) {
                ForEach(PaperStyle.sheetChoices, id: \.self) { style in
                    templateOption(style)
                }
            }

            HStack(spacing: 4) {
                ForEach(InkModel.PaperTheme.allCases, id: \.self) { theme in
                    themeOption(theme)
                }
                Spacer(minLength: 0)
                Text("A4 · Portrait")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
            .padding(.top, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .padding(.top, 22)
            .padding(.bottom, 10)
    }

    private func templateOption(_ style: PaperStyle) -> some View {
        let selected = draft.paper == style
        let paper = draft.theme.style
        return Button {
            draft.paper = style
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(paper.paper.color)
                    .overlay {
                        PaperPatternView(style.pattern, color: paper.templateLine.opacity(paper.isDark ? 0.25 : 0.4).color, spacing: 9)
                            .clipShape(.rect(cornerRadius: 7, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Tokens.Colors.fieldBorder, lineWidth: 0.5)
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Tokens.Colors.selection, lineWidth: 2.5)
                                .padding(-2.5)
                        }
                    }
                    .frame(width: 72, height: 92)
                Text(style.displayName)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Tokens.Colors.textPrimary : Tokens.Colors.textSecondary)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private func themeOption(_ theme: InkModel.PaperTheme) -> some View {
        let selected = draft.theme == theme
        return Button {
            draft.theme = theme
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.style.paper.color)
                    .overlay(Circle().strokeBorder(Tokens.Colors.swatchHairline, lineWidth: 0.8))
                    .frame(width: 16, height: 16)
                Text(theme.style.displayName)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Tokens.Colors.textPrimary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background {
                if selected {
                    Capsule().fill(Tokens.Colors.subtleFill)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        NewNotebookSheet(folder: nil) { _ in }
    }
}
