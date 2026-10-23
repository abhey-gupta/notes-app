#if DEBUG
    import DesignSystem
    import SwiftUI

    /// Temporary DEBUG-only gallery of DesignSystem components (#12).
    /// Launch args: `-DesignSystemGallery YES` opens it directly, `-DesignSystemFocus YES` starts in focus mode.
    struct DesignSystemGallery: View {
        @Environment(\.colorScheme) private var scheme
        @Environment(\.dismiss) private var dismiss
        @State private var focused = UserDefaults.standard.bool(forKey: "DesignSystemFocus")
        @State private var paperOverride: PaperTheme?
        @State private var swatch = 2

        private var paper: PaperTheme {
            paperOverride ?? (scheme == .dark ? .night : .white)
        }

        private var ink: Color {
            paper.ink(.primary).color
        }

        var body: some View {
            ZStack(alignment: .top) {
                Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()

                ScrollView {
                    page
                        .frame(maxWidth: 760)
                        .padding(.horizontal, Tokens.Spacing.xxxl)
                        .padding(.top, Tokens.Spacing.xxxl)
                        .padding(.bottom, 80)
                }
                .scrollIndicators(.hidden)

                EditorChromeSample(isFocused: $focused, title: "Design System", paper: paper)

                GlassPill.pageIndicator(current: 3, total: 11)
                    .padding(Tokens.Spacing.chromeInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .animation(.snappy, value: paper)
        }

        // MARK: Page

        private var page: some View {
            VStack(alignment: .leading, spacing: 40) {
                header
                section("Typography") { typography }
                section("Quick colors · palette") { colors }
                section("Covers") { covers }
                section("Paper") { papers }
                section("Chrome") { chrome }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaperSurface(paper))
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("Design System")
                    .font(.notebookTitle(size: 56))
                Text("tokens, type & liquid glass")
                    .font(.notebookTitle(size: 24, italic: true))
                    .opacity(0.55)
            }
            .foregroundStyle(ink)
        }

        private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Text(title)
                    .font(.sectionLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(ink.opacity(0.45))
                content()
            }
        }

        private var typography: some View {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                Text("Library").font(.libraryTitle)
                Text("Thermodynamics").font(.pagesHeading)
                Text("Lecture 7").font(.notebookTitle(size: 38, italic: true))
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }

        private var colors: some View {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(Array(Tokens.quickColors.enumerated()), id: \.offset) { index, role in
                        ColorSwatch(paper.ink(role).color, label: role.rawValue, isSelected: swatch == index) {
                            swatch = index
                        }
                    }
                }
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(Array(paper.palette.enumerated()), id: \.offset) { index, rgba in
                        ColorSwatch(
                            rgba.color,
                            label: "Color \(index + 1)",
                            isSelected: swatch == index + 3,
                            diameter: Tokens.Size.paletteSwatch
                        ) { swatch = index + 3 }
                    }
                }
            }
        }

        private var covers: some View {
            HStack(spacing: 18) {
                ForEach(CoverColor.allCases) { cover in
                    MiniCover(cover: cover)
                }
            }
        }

        private var papers: some View {
            HStack(spacing: 24) {
                ForEach(PaperTheme.allCases) { theme in
                    Button {
                        paperOverride = theme
                    } label: {
                        VStack(spacing: 10) {
                            PaperSurface(theme, showsDots: true)
                                .frame(width: 92, height: 124)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Tokens.Radius.pageThumb)
                                        .strokeBorder(Tokens.Colors.selection, lineWidth: 2.5)
                                        .padding(-5)
                                        .opacity(theme == paper ? 1 : 0)
                                }
                            Text(theme.displayName)
                                .font(.system(size: 12.5, weight: theme == paper ? .semibold : .medium))
                                .foregroundStyle(ink.opacity(theme == paper ? 0.9 : 0.5))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private var chrome: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 20) {
                    GlassCapsule {
                        ToolButton(.pen, "Pen", isActive: true, ink: paper.ink(.blue).color) {}
                        ToolButton(.highlighter, "Highlighter") {}
                        ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton) {}
                            .disabled(true)
                    }
                    GlassPill.pageIndicator(current: 3, total: 11)
                }
                HStack(spacing: 20) {
                    FocusPill(tool: .pen, ink: paper.ink(.blue).color) {}
                    Button(focused ? "Show toolbar" : "Focus mode") {
                        withAnimation(Tokens.Motion.morph) { focused.toggle() }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ink)
                    .foregroundStyle(paper.paper.color)
                    Button("Close") { dismiss() }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private struct MiniCover: View {
        let cover: CoverColor

        var body: some View {
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 7,
                topTrailingRadius: 7,
                style: .continuous
            )
            .fill(cover.color.gradient)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .frame(width: 1)
                    .padding(.leading, 6)
            }
            .frame(width: 60, height: 78)
            .shadow(Tokens.Shadows.cover)
        }
    }

    #Preview("Gallery · light") {
        DesignSystemGallery()
    }

    #Preview("Gallery · dark") {
        DesignSystemGallery()
            .preferredColorScheme(.dark)
    }
#endif
