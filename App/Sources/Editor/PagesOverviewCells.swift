import DesignSystem
import InkModel
import SwiftUI

/// One page in the overview grid (mock §04): `thumbs/<id>.heic` over paper with the page's template
/// (the placeholder until the thumb exists), 176×228 r6, a 3 pt blue ring on the current page, the
/// page number under it. Select mode adds a check badge; the ring marks selected pages instead.
struct PageThumb: View {
    let entry: PagesModel.Entry
    let number: Int
    let total: Int
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let paper: DesignSystem.PaperTheme
    /// Thumbnail cache key.
    let version: Date

    private static let size = Tokens.Size.pageThumb
    /// Template spacing scaled from page points to thumb points.
    private static let spacing = Tokens.Size.templateSpacing * Tokens.Size.pageThumb.width / Tokens.Size.pageA4.width

    var body: some View {
        let ringed = isSelecting ? isSelected : isCurrent
        VStack(spacing: 10) {
            ZStack {
                Rectangle().fill(paper.paper.color)
                PaperPatternView(entry.pattern, color: paper.templateLine.color, spacing: Self.spacing)
                if let url = entry.thumbnail {
                    ThumbnailImage(url: url, version: version)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(.rect(cornerRadius: Tokens.Radius.pageThumb))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.pageThumb + Tokens.Size.pageThumbRing)
                    .strokeBorder(Tokens.Colors.selection, lineWidth: Tokens.Size.pageThumbRing)
                    .padding(-Tokens.Size.pageThumbRing)
                    .opacity(ringed ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.white, isSelected ? Tokens.Colors.selection.color : Color.black.opacity(0.35))
                        .padding(8)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .shadow(Tokens.Shadows.thumb)
            Text("\(number)")
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? Tokens.Colors.selection.color : Tokens.Colors.textSecondary.color)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(entry.pattern.displayName)
        .accessibilityIdentifier("page-\(number)")
    }

    /// "Page 3 of 12, current" (+ ", selected").
    private var label: String {
        var label = "Page \(number) of \(total)"
        if isCurrent {
            label += ", current"
        }
        if isSelecting, isSelected {
            label += ", selected"
        }
        return label
    }
}

/// Bottom "New page" capsule: Blank / Lined / Dotted / Grid / Cornell, each a mini paper + name.
struct TemplateCapsule: View {
    let paper: DesignSystem.PaperTheme
    let onPick: (PaperStyle) -> Void

    var body: some View {
        GlassCapsule(
            height: Tokens.Size.templateCapsuleHeight, leading: Tokens.Spacing.xl, trailing: Tokens.Spacing.s, spacing: Tokens.Spacing.s
        ) {
            Text("New page")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .padding(.trailing, Tokens.Spacing.s)
                .accessibilityHidden(true)
            ForEach(PaperStyle.allCases, id: \.self) { style in
                Button {
                    onPick(style)
                } label: {
                    HStack(spacing: 7) {
                        PaperSurface(paper, pattern: style.pattern, spacing: 4, cornerRadius: 3)
                            .frame(width: 16, height: 20)
                        Text(style.displayName)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Tokens.Colors.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect(cornerRadius: Tokens.Radius.chip + 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New \(style.displayName) page")
                .accessibilityIdentifier("newPage-\(style.rawValue)")
            }
        }
    }
}

/// Header buttons: Select / Done, or in select mode Delete / Cancel.
struct OverviewHeaderButtons: View {
    let isSelecting: Bool
    let selectedCount: Int
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            if isSelecting {
                Button(selectedCount == 1 ? "Delete 1 page" : "Delete \(selectedCount) pages", role: .destructive, action: onDelete)
                    .buttonStyle(.glassProminent)
                    .tint(Tokens.Colors.inkRed.color)
                    .disabled(!canDelete)
                    .accessibilityIdentifier("pagesDelete")
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("pagesCancel")
            } else {
                Button("Select", action: onSelect)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("pagesSelect")
                Button("Done", action: onDone)
                    .buttonStyle(.glassProminent)
                    .tint(Tokens.Colors.inkPrimary.color)
                    .accessibilityIdentifier("pagesDone")
            }
        }
        .font(.chromeTitle)
    }
}
