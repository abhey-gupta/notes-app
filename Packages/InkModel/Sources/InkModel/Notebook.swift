import CoreGraphics
import Foundation

/// Paper color (per notebook, independent of system dark mode). Hex values live in `DesignSystem`.
public enum PaperTheme: String, CaseIterable, Hashable, Sendable, Codable {
    /// `#FFFFFF`.
    case white
    /// `#F6F0E1`.
    case cream
    /// `#1B1C1F`; semantic ink resolves to its dark palette.
    case night

    /// Whether ink should resolve against the dark palette.
    public var isDark: Bool {
        self == .night
    }
}

/// Procedural page background (ARCHITECTURE.md §5.3). Spacing in points.
public enum PageTemplate: Hashable, Sendable, Codable {
    /// No marks.
    case blank
    /// Horizontal rules every `spacing` pt.
    case lined(spacing: Float)
    /// Dot grid every `spacing` pt.
    case dotted(spacing: Float)
    /// Square grid every `spacing` pt.
    case grid(spacing: Float)
    /// Cornell layout (cue column, notes, summary).
    case cornell
}

/// Paper pattern picked for a notebook; new pages get its ``defaultTemplate``.
public enum PaperStyle: String, CaseIterable, Hashable, Sendable, Codable {
    /// Blank pages.
    case blank
    /// Ruled pages.
    case lined
    /// Dot-grid pages.
    case dotted
    /// Square-grid pages.
    case grid
    /// Cornell pages.
    case cornell

    /// Template for new pages. Spacings are provisional design values.
    public var defaultTemplate: PageTemplate {
        switch self {
        case .blank: .blank
        case .lined: .lined(spacing: 24)
        case .dotted: .dotted(spacing: 20)
        case .grid: .grid(spacing: 20)
        case .cornell: .cornell
        }
    }
}

/// Notebook cover swatch (8, from the mockups). Hex values live in `DesignSystem`.
public enum CoverColor: String, CaseIterable, Hashable, Sendable, Codable {
    /// `#8E9F87`.
    case sage
    /// `#C07F5E`.
    case terracotta
    /// `#2F3B57`.
    case navy
    /// `#D9C9AC`.
    case sand
    /// `#6B4A5E`.
    case plum
    /// `#3B3C40`.
    case graphite
    /// `#9DB4C9`.
    case sky
    /// `#E3A5A0`.
    case rose
}

/// Notebook metadata (manifest). Pages are referenced by ID only; their strokes live in per-page files.
public struct Notebook: Hashable, Sendable, Codable, Identifiable {
    /// A4 portrait in points, the fixed Day 0 page size.
    public static let a4Portrait = CGSize(width: 595, height: 842)

    /// Stable identity (UUIDv7).
    public let id: NotebookID
    /// Display title.
    public var title: String
    /// Cover swatch.
    public var cover: CoverColor
    /// Paper pattern for new pages.
    public var paper: PaperStyle
    /// Paper color.
    public var theme: PaperTheme
    /// When `true`, custom ink colors are not lightness-remapped on Night paper (§10).
    public var keepsExactColors: Bool
    /// Page size in points (all pages).
    public var pageSize: CGSize
    /// Page order.
    public var pages: [PageID]
    /// Creation time.
    public let createdAt: Date
    /// Last ``markModified(at:)`` time.
    public private(set) var modifiedAt: Date
    /// Manifest revision, bumped by ``markModified(at:)``. For checkpoints and future sync.
    public private(set) var rev: UInt64

    /// Creates notebook metadata.
    public init(
        id: NotebookID = NotebookID(),
        title: String,
        cover: CoverColor = .sage,
        paper: PaperStyle = .blank,
        theme: PaperTheme = .white,
        keepsExactColors: Bool = false,
        pageSize: CGSize = Notebook.a4Portrait,
        pages: [PageID] = [],
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        rev: UInt64 = 0
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.paper = paper
        self.theme = theme
        self.keepsExactColors = keepsExactColors
        self.pageSize = pageSize
        self.pages = pages
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.rev = rev
    }

    /// Records a change: bumps ``rev`` and sets ``modifiedAt``.
    public mutating func markModified(at date: Date = Date()) {
        rev &+= 1
        modifiedAt = date
    }
}
