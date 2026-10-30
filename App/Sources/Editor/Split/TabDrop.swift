import DesignSystem
import InkModel
import Library
import SwiftUI
import UniformTypeIdentifiers

/// A tab dragged out of the bar onto the page (#175): a glass sheet covers the half it would land on;
/// dropped, it opens in split view on that side.
struct TabDrop: DropDelegate {
    let geometry: SplitGeometry
    let isEnabled: Bool
    @Binding var side: OpenTabs.Pane?
    let onDrop: (NotebookID, OpenTabs.Pane) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.notebookReference])
    }

    func dropEntered(info: DropInfo) {
        let next = landing(info)
        withAnimation(.snappy(duration: 0.2)) { side = next }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = landing(info)
        if next != side {
            withAnimation(.snappy(duration: 0.2)) { side = next }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        withAnimation(.snappy(duration: 0.2)) { side = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = landing(info)
        withAnimation(.easeOut(duration: 0.2)) { side = nil }
        guard let provider = info.itemProviders(for: [.notebookReference]).first else { return false }
        _ = provider.loadDataRepresentation(for: .notebookReference) { data, _ in
            guard let data, let reference = try? JSONDecoder().decode(NotebookReference.self, from: data) else { return }
            Task { @MainActor in onDrop(reference.id, target) }
        }
        return true
    }

    private func landing(_ info: DropInfo) -> OpenTabs.Pane {
        let position = geometry.axis == .horizontal ? info.location.x : info.location.y
        return position < geometry.length / 2 ? .primary : .secondary
    }
}

/// Where a dropped tab will land: a glass sheet over that half, with the notebook's name.
struct TabDropZone: View {
    let geometry: SplitGeometry
    let side: OpenTabs.Pane
    /// The notebook being dragged, when known.
    let title: String?

    var body: some View {
        let frames = geometry.frames(SplitGeometry.half)
        let frame = (side == .primary ? frames.primary : frames.secondary).insetBy(dx: 12, dy: 12)
        VStack(spacing: Tokens.Spacing.s) {
            if let title {
                Text(title)
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text("Drop to open here")
                .scaledFont(size: 13)
                .foregroundStyle(Tokens.Colors.textTertiary)
        }
        .padding(Tokens.Spacing.xxl)
        .frame(width: frame.width, height: frame.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}
