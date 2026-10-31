import DesignSystem
import SwiftUI

/// Pages overview header: title and page count, Go to page, undo · redo, Select / Done (select mode:
/// Delete / Cancel). Compact (iPhone, #209): two rows, title · Done over Go to page · undo · redo · Select.
struct PagesOverviewHeader: View {
    let title: String
    let count: Int
    let state: EditorState
    let isSelecting: Bool
    let selectedCount: Int
    @Binding var isJumping: Bool
    let onJump: (Int) -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    @Environment(\.chromeLayout) private var chrome

    var body: some View {
        Group {
            if chrome.isCompact {
                VStack(spacing: Tokens.Spacing.l) {
                    HStack(spacing: Tokens.Spacing.m) {
                        heading
                        Spacer(minLength: Tokens.Spacing.m)
                        buttons(.second)
                    }
                    HStack(spacing: Tokens.Spacing.m) {
                        if !isSelecting {
                            jumpControl
                        }
                        undoRedo
                        Spacer(minLength: 0)
                        buttons(.first)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                    heading
                    Spacer(minLength: Tokens.Spacing.m)
                    if !isSelecting {
                        jumpControl
                    }
                    undoRedo
                    buttons(.both)
                }
            }
        }
        // Clear of an iPadOS window's controls (#118).
        .padding(.leading, chrome.margin + chrome.windowControls.leading)
        .padding(.trailing, chrome.margin)
        .padding(.top, Tokens.Spacing.xxl)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.pagesHeading)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(EditedLabel.pages(count))
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .contentTransition(.numericText())
                .accessibilityIdentifier("pagesCount")
        }
    }

    private var jumpControl: some View {
        PageJumpControl(count: count, isOpen: $isJumping, onJump: onJump)
            .transition(.opacity)
    }

    private var undoRedo: some View {
        GlassCapsule(height: Tokens.Size.focusPillHeight, leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.xs) {
            ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
                .disabled(!state.canUndo)
            ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
                .disabled(!state.canRedo)
        }
    }

    private func buttons(_ slot: OverviewHeaderButtons.Slot) -> some View {
        OverviewHeaderButtons(
            isSelecting: isSelecting,
            selectedCount: selectedCount,
            canDelete: selectedCount > 0 && selectedCount < count,
            onSelect: onSelect,
            onDelete: onDelete,
            onCancel: onCancel,
            onDone: onDone,
            slot: slot
        )
    }
}
