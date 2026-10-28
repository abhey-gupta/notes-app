import DesignSystem
import PhotosUI
import SwiftUI

/// The toolbar's photo flyout (#157): the system Photos picker embedded as a 3-wide grid of recents
/// (scroll for older), no accessory bar, no permission prompt (the picker runs out of process). One tap
/// on a photo hands its bytes to `onPick` and the flyout closes; nothing is selected across opens.
struct PhotoFlyout: View {
    let paper: PaperTheme
    let onPick: (Data) -> Void

    @State private var selection: [PhotosPickerItem] = []
    @State private var load: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Three ~88 pt cells plus the picker's own gaps.
    static let gridSide: CGFloat = 272

    var body: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: 1, selectionBehavior: .default, matching: .images) {
            EmptyView()
        }
        .photosPickerStyle(.inline)
        .photosPickerAccessoryVisibility(.hidden, edges: .all)
        .photosPickerDisabledCapabilities([.search, .stagingArea, .collectionNavigation, .selectionActions])
        .frame(width: Self.gridSide * typeSize.chromeScale, height: Self.gridSide * typeSize.chromeScale)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous))
        .padding(Tokens.Spacing.m)
        .chromePopover(for: paper)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("photoFlyout")
        .onChange(of: selection) { _, items in
            guard let item = items.first else { return }
            selection = []
            load?.cancel()
            load = Task {
                guard let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                onPick(data)
            }
        }
        .onDisappear { load?.cancel() }
    }
}
