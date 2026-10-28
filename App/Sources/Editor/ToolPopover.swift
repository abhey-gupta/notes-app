import DesignSystem
import InkEnginePencilKit
import InkModel
import SwiftUI
import Tools

/// Tool options (mock §03), opened by tapping the active tool. Pen: family, live stroke preview, size in mm
/// (#168), palette + custom color, pressure. Highlighter: preview, size, colors. Eraser: mode, 3 sizes,
/// switch back after erasing. Laser: trail or dot (#159).
/// Every control writes straight to `ToolState`, which the editor pushes to the engine, so the next stroke
/// already uses it.
struct ToolPopover: View {
    @Bindable var tools: ToolState
    let tool: Tool
    let paper: DesignSystem.PaperTheme

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tool {
            case .pen: pen
            case .highlighter: highlighter
            case .eraser: eraser
            case .lasso: EmptyView()
            case .laser: laser
            }
        }
        .padding(Tokens.Size.popoverPadding)
        .frame(width: Tokens.Size.popoverWidth * typeSize.chromeScale)
        .chromePopover(for: paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolPopover")
    }

    private var previewSize: CGSize {
        CGSize(width: Tokens.Size.popoverWidth * typeSize.chromeScale - 2 * Tokens.Size.popoverPadding, height: Tokens.Size.previewHeight)
    }

    // MARK: Pen

    @ViewBuilder private var pen: some View {
        SegmentedChoice(PenSettings.kinds, selection: $tools.pen.kind, title: \.displayName)
            .accessibilityIdentifier("penKind")
        preview(InkPreview.Spec(kind: tools.pen.kind, width: tools.pen.width, color: ink(tools.pen.color), pressure: tools.pen.pressure))
        SizeControl(size: $tools.pen.size, range: PenSettings.sizeRange(for: tools.pen.kind), id: "penSize") { position in
            Capsule()
                .fill(tools.pen.color.color(on: paper))
                .frame(width: 26, height: 1.5 + 6 * position)
        }
        SectionLabel("Color")
        PaletteGrid(colors: PaletteEntry.pen, selection: $tools.pen.color, paper: paper)
        settingToggle("Pressure sensitivity", isOn: $tools.pen.pressure)
            .accessibilityIdentifier("pressureToggle")
    }

    // MARK: Highlighter

    @ViewBuilder private var highlighter: some View {
        let color = tools.highlighter.color
        preview(InkPreview.Spec(kind: .highlighter, width: tools.highlighter.width, color: ink(color)))
            .padding(.top, -6)
        SizeControl(size: $tools.highlighter.size, range: HighlighterSettings.sizeRange, id: "highlighterSize") { position in
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color.color(on: paper).opacity(0.7))
                .frame(width: 26, height: 3 + 6 * position)
        }
        SectionLabel("Color")
        PaletteGrid(colors: PaletteEntry.highlighter, selection: $tools.highlighter.color, paper: paper)
    }

    // MARK: Eraser

    @ViewBuilder private var eraser: some View {
        let mode = tools.eraser.mode
        SegmentedChoice(EraserSettings.Mode.allCases, selection: $tools.eraser.mode, title: \.displayName)
            .accessibilityIdentifier("eraserMode")
        Text(mode.caption)
            .scaledFont(size: 13)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .contentTransition(.opacity)
            .animation(Tokens.Motion.inkCrossfade, value: mode)
            .padding(.top, Tokens.Spacing.m)
            .padding(.horizontal, Tokens.Spacing.xs)
        SectionLabel("Size")
        OptionRow(values: EraserSettings.widths, selection: $tools.eraser.widthIndex, label: "Size") { index, selected in
            Circle()
                .strokeBorder(selected ? Tokens.Colors.iconActive : Tokens.Colors.icon, lineWidth: 1.5)
                .frame(width: Tokens.Size.eraserWidthRings[index], height: Tokens.Size.eraserWidthRings[index])
        }
        settingToggle("Switch back after erasing", isOn: $tools.eraser.autoDeselect)
            .accessibilityIdentifier("eraserAutoDeselectToggle")
    }

    // MARK: Laser

    @ViewBuilder private var laser: some View {
        let mode = tools.laser.mode
        SegmentedChoice(LaserSettings.Mode.allCases, selection: $tools.laser.mode, title: \.displayName)
            .accessibilityIdentifier("laserMode")
        Text(mode.caption)
            .scaledFont(size: 13)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .contentTransition(.opacity)
            .animation(Tokens.Motion.inkCrossfade, value: mode)
            .padding(.top, Tokens.Spacing.m)
            .padding(.horizontal, Tokens.Spacing.xs)
    }

    // MARK: Pieces

    /// On/off row under a hairline, closing a tool's options.
    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .scaledFont(size: 14, weight: .medium)
            .foregroundStyle(Tokens.Colors.textPrimary)
            .padding(.top, 12)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.bottom, 2)
            .overlay(alignment: .top) {
                Rectangle().fill(Tokens.Colors.separator).frame(height: 0.5)
            }
            .padding(.top, 18)
            .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
    }

    private func preview(_ spec: InkPreview.Spec) -> some View {
        StrokePreview(spec: spec, size: previewSize, paper: paper.paper.color)
            .padding(.top, 12)
            .padding(.bottom, Tokens.Spacing.s)
    }

    /// Ink as the canvas draws it on this paper.
    private func ink(_ color: InkColor) -> RGBA8 {
        DesignSystemInkPalette().ink(color, on: paper.model)
    }
}

// MARK: - Stroke preview

/// PencilKit-drawn sample stroke on the notebook's paper (``InkPreview``). A new pen family writes itself in
/// left to right; width, color and pressure changes crossfade.
private struct StrokePreview: View {
    let spec: InkPreview.Spec
    let size: CGSize
    let paper: Color

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layer: Layer?

    struct Layer: Identifiable {
        let id: Int
        let image: UIImage
        /// Writes itself in instead of fading in.
        let writes: Bool
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
                .fill(paper)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
                        .strokeBorder(Tokens.Colors.fieldBorder, lineWidth: 0.5)
                }
            if let layer {
                InkLayer(layer: layer, width: size.width, animates: !reduceMotion)
                    .id(layer.id)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(Tokens.Motion.inkCrossfade, value: layer?.id)
        .accessibilityHidden(true)
        .onChange(of: spec, initial: true) { old, new in
            let image = InkPreview.image(new, size: size, scale: displayScale)
            let writes = layer == nil || old.kind != new.kind
            layer = Layer(id: (layer?.id ?? 0) + 1, image: image, writes: writes)
        }
    }
}

private struct InkLayer: View {
    let layer: StrokePreview.Layer
    let width: CGFloat
    @State private var progress: CGFloat

    init(layer: StrokePreview.Layer, width: CGFloat, animates: Bool) {
        self.layer = layer
        self.width = width
        _progress = State(initialValue: animates && layer.writes ? 0 : 1)
    }

    /// Soft leading edge of the reveal.
    private static let feather: CGFloat = 28

    var body: some View {
        Image(uiImage: layer.image)
            .resizable()
            .mask(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().frame(width: (width + Self.feather) * progress)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.feather)
                }
                .offset(x: -Self.feather)
            }
            .onAppear {
                guard progress < 1 else { return }
                withAnimation(Tokens.Motion.inkReveal) {
                    progress = 1
                }
            }
    }
}
