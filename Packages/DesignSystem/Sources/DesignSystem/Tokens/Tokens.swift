import SwiftUI

/// Design tokens from `design/mockups-v1.html` (ARCHITECTURE.md §10). The only place hex values live.
public enum Tokens {
    // MARK: Colors (chrome; follow system appearance)

    public enum Colors {
        public static let desk = DynamicColor(light: RGBA(0xEDEAE4), dark: RGBA(0x0F1012))
        public static let libraryBackground = DynamicColor(light: RGBA(0xF3F1EC), dark: RGBA(0x141517))

        public static let inkPrimary = DynamicColor(light: RGBA(0x1E2129), dark: RGBA(0xE9E8E4))
        public static let inkBlue = DynamicColor(light: RGBA(0x2C4FD6), dark: RGBA(0x5FD3C4))
        public static let inkRed = DynamicColor(light: RGBA(0xD2402F), dark: RGBA(0xFF8FB1))
        public static let inkAccent = DynamicColor(light: RGBA(0xE0A400), dark: RGBA(0xFFC764))

        /// Mock glass values. Native Liquid Glass draws its own; these are for non-SwiftUI overlays (Metal HUDs).
        public static let glassFill = DynamicColor(light: RGBA(0xFFFFFF, alpha: 0.72), dark: RGBA(0x28292E, alpha: 0.72))
        public static let glassBorder = DynamicColor(light: RGBA(0x000000, alpha: 0.07), dark: RGBA(0xFFFFFF, alpha: 0.10))

        public static let textPrimary = DynamicColor(light: RGBA(0x1E2129), dark: RGBA(0xECECEE))
        public static let textSecondary = DynamicColor(light: RGBA(0x666970), dark: RGBA(0xA9ABB2))
        public static let textTertiary = DynamicColor(light: RGBA(0x6A6D74), dark: RGBA(0x8D8F96))

        /// Toolbar glyphs at rest / active.
        public static let icon = DynamicColor(light: RGBA(0x3A3D45), dark: RGBA(0xD6D7DB))
        public static let iconActive = DynamicColor(light: RGBA(0x1E2129), dark: RGBA(0xE8E8EA))
        public static let pillText = DynamicColor(light: RGBA(0x55585F), dark: RGBA(0xA9ABB2))
        public static let separator = DynamicColor(light: RGBA(0x000000, alpha: 0.10), dark: RGBA(0xFFFFFF, alpha: 0.14))
        /// Drop slot shown at the toolbar's target dock while it is dragged.
        public static let dockHint = DynamicColor(light: RGBA(0x1E2129, alpha: 0.05), dark: RGBA(0xFFFFFF, alpha: 0.06))
        public static let dockHintBorder = DynamicColor(light: RGBA(0x1E2129, alpha: 0.16), dark: RGBA(0xFFFFFF, alpha: 0.20))
        /// Hairline around swatches so light colors read on light glass.
        public static let swatchHairline = DynamicColor(light: RGBA(0x000000, alpha: 0.15), dark: RGBA(0xFFFFFF, alpha: 0.18))

        public static let templateLine = DynamicColor(light: RGBA(0x1E2129, alpha: 0.16), dark: RGBA(0xFFFFFF, alpha: 0.09))
        public static let selection = DynamicColor(light: RGBA(0x2C4FD6), dark: RGBA(0x5FD3C4))

        /// Library folder chips at rest.
        public static let chipText = DynamicColor(light: RGBA(0x5B5E66), dark: RGBA(0xA9ABB2))
        /// Subtle selected fill for chips / segmented rows (`rgba(30,33,41,.07)`).
        public static let subtleFill = DynamicColor(light: RGBA(0x1E2129, alpha: 0.07), dark: RGBA(0xFFFFFF, alpha: 0.10))
        /// Library sidebar folder glyph: warm paper tone, quieter than cover cloth.
        public static let folder = DynamicColor(light: RGBA(0xC2B7A3), dark: RGBA(0x8C8576))
        /// New-notebook sheet: cover preview panel and text field.
        public static let sheetPanel = DynamicColor(light: RGBA(0xEFECE6), dark: RGBA(0x1C1D21))
        public static let field = DynamicColor(light: RGBA(0xFFFFFF), dark: RGBA(0x2A2B30))
        public static let fieldBorder = DynamicColor(light: RGBA(0x000000, alpha: 0.10), dark: RGBA(0xFFFFFF, alpha: 0.12))
    }

    // MARK: Ink

    /// Pen palette (11), light-paper values. Night remap is the renderer's job (§10 ink color model).
    public static let palette: [RGBA] = [
        RGBA(0x1E2129), RGBA(0x5D6470), RGBA(0x2C4FD6), RGBA(0x1E8E6E), RGBA(0xD2402F), RGBA(0xE07A1F),
        RGBA(0x7E4FD8), RGBA(0xC2457E), RGBA(0x0FA3B1), RGBA(0x8D6E4C), RGBA(0xE8B800),
    ]

    /// Default quick-color slots (§6).
    public static let quickColors: [InkRole] = [.primary, .blue, .red]

    /// Highlighter yellow from the mock (`rgba(255,214,51,.55)`), multiplied under ink.
    public static let highlighter = RGBA(0xFFD633, alpha: 0.55)

    /// Highlighter colors: mock yellow + a palette subset, opaque (the marker ink adds translucency).
    public static let highlighterPalette: [RGBA] = [
        RGBA(0xFFD633), RGBA(0xE07A1F), RGBA(0xC2457E), RGBA(0x7E4FD8), RGBA(0x0FA3B1), RGBA(0x1E8E6E),
    ]

    // MARK: Spacing

    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 10
        public static let l: CGFloat = 14
        public static let xl: CGFloat = 18
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 44

        /// Library page margin.
        public static let libraryMargin: CGFloat = 44
        /// Library sidebar: inset from the screen edges; nested folder indent.
        public static let sidebarInset: CGFloat = 12
        public static let sidebarIndent: CGFloat = 18

        /// Capsule inset from the screen edge.
        public static let chromeInset: CGFloat = 18
        /// Gap between glass capsules before they blend (GlassEffectContainer spacing).
        public static let glassBlend: CGFloat = 24
    }

    // MARK: Radii

    public enum Radius {
        public static let page: CGFloat = 4
        public static let pageThumb: CGFloat = 6
        public static let coverSpine: CGFloat = 5
        public static let coverEdge: CGFloat = 12
        public static let field: CGFloat = 12
        public static let pill: CGFloat = 14
        public static let chip: CGFloat = 16
        public static let toolButton: CGFloat = 20
        public static let popover: CGFloat = 24
        /// Tool popover: segmented track, its selected segment, the stroke preview.
        public static let segmented: CGFloat = 12
        public static let segment: CGFloat = 9
        public static let preview: CGFloat = 14
        public static let capsule: CGFloat = 26
        public static let sheet: CGFloat = 30
    }

    // MARK: Geometry

    public enum Size {
        public static let capsuleHeight: CGFloat = 52
        public static let toolButton = CGSize(width: 44, height: 40)
        public static let compactToolButton = CGSize(width: 40, height: 40)
        public static let toolIcon: CGFloat = 19
        public static let activeDot: CGFloat = 4
        public static let swatch: CGFloat = 22
        public static let paletteSwatch: CGFloat = 30
        /// Selected ring = `swatchRingGap` clear + (`swatchRingOuter` − gap) of color.
        public static let swatchRingGap: CGFloat = 2
        public static let swatchRingOuter: CGFloat = 3.5
        public static let separator = CGSize(width: 1, height: 22)
        public static let focusPillHeight: CGFloat = 44
        public static let focusToolButton = CGSize(width: 38, height: 34)
        public static let focusSwatch: CGFloat = 18
        public static let pageThumb = CGSize(width: 176, height: 228)
        /// Pages overview: ring on the current / selected page, gap between thumbs, template capsule.
        public static let pageThumbRing: CGFloat = 3
        public static let pageThumbGap: CGFloat = 32
        public static let templateCapsuleHeight: CGFloat = 56
        public static let cover = CGSize(width: 150, height: 196)
        /// Library "Continue" card: 344 wide, 196 tall preview, r12.
        public static let recentCard = CGSize(width: 344, height: 196)
        public static let recentRadius: CGFloat = 12
        /// Library sidebar panel width; window width from which it docks beside the covers (else overlays).
        public static let sidebarWidth: CGFloat = 280
        public static let sidebarDockWidth: CGFloat = 1000
        public static let popoverWidth: CGFloat = 328
        public static let popoverPadding: CGFloat = 16
        /// Tool popover stroke preview height.
        public static let previewHeight: CGFloat = 72
        /// Width / size option hit circle.
        public static let widthOption: CGFloat = 40
        /// Width option glyphs: pen dots (mock 3/5/8/11/15), highlighter chisel heights, eraser rings.
        public static let penWidthDots: [CGFloat] = [3, 5, 8, 11, 15]
        public static let highlighterWidthBars: [CGFloat] = [6, 10, 15]
        public static let eraserWidthRings: [CGFloat] = [10, 17, 26]
        /// A4 portrait in points.
        public static let pageA4 = CGSize(width: 595, height: 842)
        public static let templateSpacing: CGFloat = 24
        public static let templateDot: CGFloat = 1.1
    }

    // MARK: Shadows

    public enum Shadows {
        /// `0 12 40 -12 rgba(40,30,10,.18)`.
        public static let page = ShadowToken(color: RGBA(0x281E0A, alpha: 0.18), radius: 16, y: 12)
        /// `0 1 2 rgba(0,0,0,.06)` contact shadow under the page.
        public static let pageContact = ShadowToken(color: RGBA(0x000000, alpha: 0.06), radius: 1, y: 1)
        /// Night paper floats on a dark desk: `0 20 50 -10 rgba(0,0,0,.6)`.
        public static let pageNight = ShadowToken(color: RGBA(0x000000, alpha: 0.55), radius: 22, y: 18)
        /// `0 14 28 -12 rgba(30,20,10,.35)`.
        public static let cover = ShadowToken(color: RGBA(0x1E140A, alpha: 0.30), radius: 10, y: 10)
        public static let thumb = ShadowToken(color: RGBA(0x1E140A, alpha: 0.25), radius: 9, y: 8)
    }

    // MARK: Motion

    public enum Motion {
        /// Toolbar ↔ focus pill morph. ≤ 250 ms (#13 acceptance).
        public static let morph: Animation = .spring(duration: 0.25, bounce: 0.12)
        /// Morph replacement under Reduce Motion: a short crossfade.
        public static let reducedMorph: Animation = .easeInOut(duration: 0.15)
        /// Toolbar tracking the finger while dragged: near-critically damped, so it trails by a frame or two.
        public static let dragFollow: Animation = .interactiveSpring(response: 0.16, dampingFraction: 0.86)
        /// Toolbar released: flies to its dock (position + axis re-flow) with a little settle.
        public static let dock: Animation = .spring(duration: 0.42, bounce: 0.18)
        /// Pages overview open/close: the page zooms into its grid cell and back (#124).
        public static let pageZoom: Animation = .spring(duration: 0.35, bounce: 0.08)
        /// Continuous inking before chrome collapses (§7).
        public static let focusDelay: Duration = .milliseconds(1500)
        /// A page's thumbnail giving way to its sharp raster (editor open, #43; page images, #70).
        public static let thumbnailCrossfadeDuration: TimeInterval = 0.12
        public static let thumbnailCrossfade: Animation = .easeOut(duration: thumbnailCrossfadeDuration)
        /// Popover selection highlight (segment, width) sliding to a new option.
        public static let selection: Animation = .spring(duration: 0.32, bounce: 0.22)
        /// Stroke preview: new ink writes itself in left to right / crossfades.
        public static let inkReveal: Animation = .easeInOut(duration: 0.5)
        public static let inkCrossfade: Animation = .easeOut(duration: 0.18)
    }
}

/// Semantic ink slots. Resolve per paper theme (`PaperTheme.ink(_:)`).
public enum InkRole: String, CaseIterable, Codable, Sendable {
    case primary, blue, red, accent
}

/// `color`/`radius`/offset in SwiftUI terms (CSS blur ≈ 2 × radius; negative spread folded into radius).
public struct ShadowToken: Hashable, Sendable {
    public var color: RGBA
    public var radius: CGFloat
    public var x: CGFloat
    public var y: CGFloat

    public init(color: RGBA, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

public extension View {
    func shadow(_ token: ShadowToken) -> some View {
        shadow(color: token.color.color, radius: token.radius, x: token.x, y: token.y)
    }
}
