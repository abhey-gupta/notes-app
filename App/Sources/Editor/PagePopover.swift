import DesignSystem
import SwiftUI
import Tools

/// The ⋯ popover (#126): Paper swatches, Template thumbnails, "Keep exact colors" (Night only), then Share (compact
/// chrome, #118) and Focus mode. DEBUG adds the toolbar dock picker.
struct PagePopover: View {
    let tools: ToolState
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    /// "Keep exact colors", offered on Night paper.
    @Binding var keepsExactColors: Bool
    /// Compact chrome's share row; `nil` hides it.
    var onShare: (() -> Void)?
    let onFocus: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isCompactLayout) private var isCompactLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Paper")
            HStack(spacing: Tokens.Spacing.l) {
                ForEach(PaperTheme.allCases) { theme in
                    paperOption(theme)
                }
            }
            .padding(.horizontal, Tokens.Spacing.xs)
            label("Template")
                .padding(.top, 18)
            HStack(spacing: 0) {
                ForEach(PaperPattern.allCases) { pattern in
                    templateOption(pattern)
                        .frame(maxWidth: .infinity)
                }
            }
            if paper == .night {
                exactColorsToggle
                    .transition(.reveal)
            }
            Divider()
                .padding(.vertical, 12)
            if let onShare {
                row("Share", symbol: .share, action: onShare)
                    .accessibilityIdentifier("shareRow")
                    .padding(.bottom, 14)
            }
            row("Focus mode", symbol: .focus, action: onFocus)
            #if DEBUG
                // Compact chrome always docks at the bottom.
                if !isCompactLayout {
                    Picker("Toolbar dock (debug)", selection: dockBinding) {
                        ForEach(ToolbarDock.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .scaledFont(size: 14, weight: .medium)
                    .padding(.top, 8)
                }
            #endif
        }
        .padding(Tokens.Size.popoverPadding)
        .frame(width: Tokens.Size.popoverWidth * typeSize.chromeScale)
        .animation(.snappy(duration: 0.28), value: paper == .night)
        .presentationCompactAdaptation(.popover)
        .dynamicTypeSize(...DynamicTypeSize.chromeLimit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pagePopover")
    }

    /// Below the templates so nothing above moves when it slides open on Night.
    private var exactColorsToggle: some View {
        Toggle(isOn: $keepsExactColors) {
            Label("Keep exact colors", systemImage: "eyedropper")
        }
        .scaledFont(size: 14, weight: .medium)
        .foregroundStyle(Tokens.Colors.chromeText)
        .tint(Tokens.Colors.selection.color)
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.top, 14)
        .accessibilityIdentifier("keepExactColors")
    }

    private func row(_ title: String, symbol: Symbol, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .scaledFont(size: 14, weight: .medium)
        .foregroundStyle(Tokens.Colors.chromeText)
        .padding(.horizontal, Tokens.Spacing.xs)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11.5, weight: .semibold)
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(Tokens.Colors.chromeHeader)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    /// Paper color dot; the current one gets a selection ring.
    private func paperOption(_ theme: PaperTheme) -> some View {
        let selected = paper == theme
        return Button {
            paper = theme
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(theme.paper.color)
                    .overlay(Circle().strokeBorder(Tokens.Colors.swatchHairline, lineWidth: 0.8))
                    .frame(width: 30, height: 30)
                    .overlay {
                        if selected {
                            Circle()
                                .strokeBorder(Tokens.Colors.selection, lineWidth: 2)
                                .padding(-4)
                        }
                    }
                    .padding(4)
                Text(theme.displayName)
                    .scaledFont(size: 12, weight: selected ? .semibold : .medium)
                    .foregroundStyle(selected ? Tokens.Colors.chromeText : Tokens.Colors.chromeTextSecondary)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(theme.displayName) paper")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("paper.\(theme.rawValue)")
        .animation(.snappy(duration: 0.2), value: selected)
    }

    /// Mini page in the current paper color with the pattern drawn on it.
    private func templateOption(_ option: PaperPattern) -> some View {
        let selected = pattern == option
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button {
            pattern = option
        } label: {
            VStack(spacing: 6) {
                shape
                    .fill(paper.paper.color)
                    .overlay {
                        PaperPatternView(option, color: paper.templateLine.opacity(paper.isDark ? 0.3 : 0.5).color, spacing: 6)
                            .clipShape(shape)
                    }
                    .overlay(shape.strokeBorder(Tokens.Colors.fieldBorder, lineWidth: 0.5))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Tokens.Colors.selection, lineWidth: 2)
                                .padding(-3)
                        }
                    }
                    .frame(width: 40, height: 54)
                    .animation(nil, value: paper) // recolor with the page, no crossfade
                    .padding(3)
                Text(option.displayName)
                    .scaledFont(size: 11, weight: selected ? .semibold : .medium)
                    .foregroundStyle(selected ? Tokens.Colors.chromeText : Tokens.Colors.chromeTextSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(option.displayName) template")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("template.\(option.rawValue)")
        .animation(.snappy(duration: 0.2), value: selected)
    }

    #if DEBUG
        private var dockBinding: Binding<ToolbarDock> {
            Binding { tools.dock } set: { tools.dock = $0 }
        }
    #endif
}

private extension AnyTransition {
    /// Unrolls from the top edge as the rows below slide down; fading alone left the switch popping in.
    static var reveal: AnyTransition {
        .modifier(active: RevealModifier(progress: 0), identity: RevealModifier(progress: 1))
    }
}

private nonisolated struct RevealModifier: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .mask(alignment: .top) {
                GeometryReader { proxy in
                    Rectangle().frame(height: proxy.size.height * progress)
                }
            }
    }
}
