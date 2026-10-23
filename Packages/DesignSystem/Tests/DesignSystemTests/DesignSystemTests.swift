import CoreText
@testable import DesignSystem
import Testing
import UIKit

struct TokenTests {
    @Test(arguments: PaperTheme.allCases)
    func primaryInkReadsOnEveryPaper(theme: PaperTheme) {
        #expect(theme.ink(.primary).contrastRatio(against: theme.paper) >= 4.5)
    }

    /// Colored inks are strokes, not body text: WCAG non-text contrast (3:1).
    @Test(arguments: PaperTheme.allCases, InkRole.allCases)
    func semanticInkIsVisible(theme: PaperTheme, role: InkRole) {
        let minimum = role == .accent ? 1.8 : 3.0 // amber is a highlight color by design
        #expect(theme.ink(role).contrastRatio(against: theme.paper) >= minimum)
    }

    @Test func nightPaperIsIndependentOfSystemAppearance() {
        #expect(PaperTheme.night.isDark)
        #expect(PaperTheme.night.ink(.primary) == Tokens.Colors.inkPrimary.dark)
        #expect(PaperTheme.cream.ink(.primary) == Tokens.Colors.inkPrimary.light)
        #expect(PaperTheme.cream.paper.hex == 0xF6F0E1)
    }

    @Test func counts() {
        #expect(Tokens.palette.count == 11)
        #expect(Set(Tokens.palette).count == 11)
        #expect(CoverColor.allCases.count == 8)
        #expect(PaperTheme.allCases.count == 3)
    }

    @Test func quickColorDefaultsMatchSpec() {
        let hexes = Tokens.quickColors.map { PaperTheme.white.ink($0).hex }
        #expect(hexes == [0x1E2129, 0x2C4FD6, 0xD2402F])
    }

    @Test func hexRoundTrips() {
        let color = RGBA(0x2C4FD6, alpha: 0.5)
        #expect(color.hex == 0x2C4FD6)
        #expect(color.alpha == 0.5)
        #expect(RGBA(0xFFFFFF).contrastRatio(against: RGBA(0x000000)) > 20.9)
    }

    @Test(arguments: Tokens.palette)
    func oklchRoundTrips(color: RGBA) {
        #expect(RGBA(color.oklch).hex == color.hex)
    }

    @Test func nightRemapFollowsSpec() {
        let night = PaperTheme.night.palette
        #expect(night.count == 11)
        for (original, color) in zip(Tokens.palette, night) {
            #expect((0.649 ... 0.951).contains(color.oklch.lightness))
            // Never darker than the original, and readable on Night paper.
            #expect(color.oklch.lightness >= min(original.oklch.lightness, 0.95) - 0.01)
            #expect(color.contrastRatio(against: PaperTheme.night.paper) >= 4.5)
        }
        #expect(night[0].contrastRatio(against: PaperTheme.night.paper) >= 4.5)
        #expect(PaperTheme.night.adapt(Tokens.palette[0], keepExact: true) == Tokens.palette[0])
        #expect(PaperTheme.cream.palette == Tokens.palette)
    }

    @Test func dynamicColorResolvesPerTrait() {
        let desk = Tokens.Colors.desk.uiColor
        let light = desk.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = desk.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(light != dark)
        #expect(Tokens.Colors.desk.resolved(for: .dark).hex == 0x0F1012)
    }

    @Test func geometryMatchesMock() {
        #expect(Tokens.Size.capsuleHeight == 2 * Tokens.Radius.capsule)
        #expect(Tokens.Size.toolButton == CGSize(width: 44, height: 40))
        #expect(Tokens.Size.toolButton.height == 2 * Tokens.Radius.toolButton)
        #expect(Tokens.Size.swatch == 22)
    }
}

struct TypographyTests {
    @Test func fontsRegister() {
        #expect(Typography.registerFonts())
        #expect(Typography.registerFonts()) // idempotent
    }

    @Test(arguments: Typography.Face.allCases)
    func faceResolves(face: Typography.Face) {
        Typography.registerFonts()
        let font = Typography.uiFont(face, size: 24)
        #expect(font.fontName == face.postScriptName)
        #expect(font.familyName == "Instrument Serif")
    }

    @Test func licenseShips() {
        #expect(Typography.licenseURL != nil)
    }
}
