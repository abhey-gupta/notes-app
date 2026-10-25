import CoreText
import os
import SwiftUI
import UIKit

/// Instrument Serif (OFL, bundled) for notebook titles and headings; SF Pro for everything else.
public enum Typography {
    public enum Face: String, CaseIterable, Sendable {
        case regular = "InstrumentSerif-Regular"
        case italic = "InstrumentSerif-Italic"

        /// PostScript name == file name for these fonts.
        public var postScriptName: String {
            rawValue
        }
    }

    /// Registers bundled fonts with CoreText once per process. Cheap to call repeatedly.
    @discardableResult
    public static func registerFonts() -> Bool {
        registration
    }

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "DesignSystem")

    private static let registration: Bool = Face.allCases.allSatisfy { face in
        guard let url = Bundle.module.url(forResource: face.rawValue, withExtension: "ttf") else {
            log.error("Missing font resource \(face.rawValue, privacy: .public)")
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }
        // Already registered (e.g. by a previous test host) is fine.
        let cfError = error?.takeRetainedValue()
        if let cfError, CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
            return true
        }
        log.error("Font registration failed: \(String(describing: cfError), privacy: .public)")
        return false
    }

    /// SIL OFL 1.1, shipped alongside the fonts (Settings → Acknowledgements).
    public static var licenseURL: URL? {
        Bundle.module.url(forResource: "OFL", withExtension: "txt")
    }

    public static func uiFont(_ face: Face = .regular, size: CGFloat) -> UIFont {
        registerFonts()
        return UIFont(name: face.postScriptName, size: size) ?? .systemFont(ofSize: size)
    }
}

public extension Font {
    /// Instrument Serif for notebook titles. Scales with Dynamic Type relative to `.title`.
    static func notebookTitle(size: CGFloat, italic: Bool = false) -> Font {
        Typography.registerFonts()
        let face: Typography.Face = italic ? .italic : .regular
        return .custom(face.postScriptName, size: size, relativeTo: .title)
    }

    /// "Library" (46).
    static var libraryTitle: Font {
        notebookTitle(size: 46)
    }

    /// Pages overview heading, e.g. "Thermodynamics" (38).
    static var pagesHeading: Font {
        notebookTitle(size: 38)
    }

    /// Cover label (15).
    static var coverLabel: Font {
        notebookTitle(size: 15)
    }

    // Chrome fonts are text styles (15 / 12 / 13 / 12 pt at the default size) so they follow Dynamic Type.

    /// Toolbar title, chips, buttons.
    static var chromeTitle: Font {
        .subheadline.weight(.semibold)
    }

    /// "3 of 11".
    static var pill: Font {
        .caption.weight(.semibold).monospacedDigit()
    }

    /// Uppercase section labels ("CONTINUE", "THICKNESS"). Pair with `.sectionLabelStyle()`.
    static var sectionLabel: Font {
        .footnote.weight(.semibold)
    }

    /// Card meta lines ("Edited 2 min ago · 11 pages").
    static var meta: Font {
        .caption
    }
}

public extension View {
    /// Uppercase, tracked, secondary — the mock's section label treatment.
    func sectionLabelStyle() -> some View {
        font(.sectionLabel)
            .textCase(.uppercase)
            .tracking(13 * 0.06)
            .foregroundStyle(Tokens.Colors.textSecondary)
    }
}
