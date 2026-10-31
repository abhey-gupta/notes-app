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
    /// Off while the page flies between the canvas and this cell (#124): the flyer shows the same pixels.
    var showsContent = true
    /// Ring and number: they fade in as the page lands and out as it takes off (`chromeAnimation`).
    var showsChrome = true
    var chromeAnimation: Animation?
    /// Arrival halo after "Go to page" (#214): 1 while lifted, fading to 0.
    var halo: Double = 0
    /// Smaller in the compact two-column grid (#209).
    var size = Tokens.Size.pageThumb

    private static let haloWidth: CGFloat = 10

    /// Template spacing scaled from page points to thumb points.
    private var spacing: CGFloat {
        Tokens.Size.templateSpacing * size.width / Tokens.Size.pageA4.width
    }

    var body: some View {
        let ringed = (isSelecting ? isSelected : isCurrent) && showsChrome
        VStack(spacing: 10) {
            ZStack {
                Rectangle().fill(paper.paper.color)
                PaperPatternView(entry.pattern, color: paper.templateLine.color, spacing: spacing)
                if let url = entry.thumbnail {
                    ThumbnailImage(url: url, version: version)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: Tokens.Radius.pageThumb))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.pageThumb + Tokens.Size.pageThumbRing)
                    .strokeBorder(Tokens.Colors.selection, lineWidth: Tokens.Size.pageThumbRing)
                    .padding(-Tokens.Size.pageThumbRing)
                    .opacity(ringed ? 1 : 0)
                    .animation(chromeAnimation, value: ringed)
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .scaledFont(size: 22, weight: .semibold)
                        .foregroundStyle(Color.white, isSelected ? Tokens.Colors.selection.color : Color.black.opacity(0.35))
                        .padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.pageThumb + Tokens.Size.pageThumbRing)
                    .strokeBorder(Tokens.Colors.selection, lineWidth: Tokens.Size.pageThumbRing)
                    .padding(-Tokens.Size.pageThumbRing)
                    .opacity(halo)
            }
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .shadow(Tokens.Shadows.thumb)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.pageThumb + Self.haloWidth)
                    .fill(Tokens.Colors.selection.color.opacity(0.2))
                    .padding(-Self.haloWidth)
                    .opacity(halo)
            }
            .opacity(showsContent ? 1 : 0)
            Text("\(number)")
                .scaledFont(size: 12.5, weight: isCurrent || halo > 0 ? .semibold : .medium)
                .foregroundStyle(isCurrent || halo > 0 ? Tokens.Colors.selection.color : Tokens.Colors.textSecondary.color)
                .opacity(showsChrome ? 1 : 0)
                .animation(chromeAnimation, value: showsChrome)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelecting && isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(label)
        .accessibilityValue(entry.pattern.displayName)
        .accessibilityHint(isSelecting ? "Toggles selection" : "Opens this page")
        .accessibilityIdentifier("page-\(number)")
    }

    /// "Page 3 of 12, current".
    private var label: String {
        isCurrent ? "Page \(number) of \(total), current" : "Page \(number) of \(total)"
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
                .scaledFont(size: 13.5, weight: .medium)
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
                            .scaledFont(size: 13.5, weight: .medium)
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

/// Compact "New page" (#209): one glass button, the templates in its menu.
struct TemplateMenuButton: View {
    let onPick: (PaperStyle) -> Void

    var body: some View {
        Menu {
            ForEach(PaperStyle.allCases, id: \.self) { style in
                Button(style.displayName) { onPick(style) }
                    .accessibilityIdentifier("newPage-\(style.rawValue)")
            }
        } label: {
            GlassCapsule(
                height: Tokens.Size.templateCapsuleHeight,
                leading: Tokens.Spacing.xl,
                trailing: Tokens.Spacing.xl,
                spacing: Tokens.Spacing.s
            ) {
                Image(systemName: "plus")
                    .scaledFont(size: 15, weight: .semibold)
                Text("New page")
                    .scaledFont(size: 15, weight: .medium)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textTertiary)
            }
            .foregroundStyle(Tokens.Colors.textPrimary)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("New page")
        .accessibilityIdentifier("newPageMenu")
    }
}

/// Header buttons: Select / Done, or in select mode Delete / Cancel; compact headers split them across
/// two rows (`slot`).
struct OverviewHeaderButtons: View {
    let isSelecting: Bool
    let selectedCount: Int
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    var slot = Slot.both

    enum Slot {
        /// Select or Delete, then Done or Cancel.
        case both
        /// Select or Delete.
        case first
        /// Done or Cancel.
        case second
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            if slot != .second {
                if isSelecting {
                    Button(selectedCount == 1 ? "Delete 1 page" : "Delete \(selectedCount) pages", role: .destructive, action: onDelete)
                        .buttonStyle(.glassProminent)
                        .tint(Tokens.Colors.inkRed.color)
                        .disabled(!canDelete)
                        .accessibilityIdentifier("pagesDelete")
                } else {
                    Button("Select", action: onSelect)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("pagesSelect")
                }
            }
            if slot != .first {
                if isSelecting {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("pagesCancel")
                } else {
                    Button("Done", action: onDone)
                        .buttonStyle(.glassProminent)
                        .tint(Tokens.Colors.textPrimary.color)
                        // Light capsule in dark mode: the label flips with it.
                        .foregroundStyle(Tokens.Colors.libraryBackground)
                        .accessibilityIdentifier("pagesDone")
                }
            }
        }
        .font(.chromeTitle)
        .fixedSize()
    }
}
