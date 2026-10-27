#if canImport(UIKit)
    import InkGeometry
    import InkModel
    import UIKit

    /// A label with 6 × 10 pt padding.
    final class PaddedLabel: UILabel {
        private let padding = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: padding))
        }

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
        }
    }

    /// The live paper beside one page during a grab (content space): paper added shows the page's
    /// template continued on its grid (a tiled mark, phase-aligned, so growing it costs no re-rasterizing)
    /// with a hairline at the original edge; paper taken away is covered in desk color. The strip's
    /// bounds origin is kept equal to its page x, so sublayers are laid out in page coordinates.
    final class PreviewStrip: UIView {
        private let pattern = CALayer()
        private let summaryRule = CALayer()
        private let seam = CALayer()
        private var tileKey: TileKey?
        private var page = CGRect.zero
        private var appearance: PaperAppearance?

        private struct TileKey: Equatable {
            var template: PageTemplate
            var pixelScale: CGFloat
            var line: UIColor
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            clipsToBounds = true
            for sub in [pattern, summaryRule, seam] {
                sub.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
                layer.addSublayer(sub)
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        /// How a strip's marks continue its page.
        struct Marks {
            var template: PageTemplate
            /// The page's frame (content space).
            var page: CGRect
            /// The notebook's original page width (bounds how far a strip can reach).
            var baseWidth: CGFloat
            /// Paper already added on the left (phases the columns).
            var leftExtension: CGFloat
            /// Pixels per point the tile is drawn at.
            var pixelScale: CGFloat
        }

        /// The page this strip belongs to and how its marks continue.
        func configure(_ marks: Marks, appearance: PaperAppearance) {
            let (template, page, baseWidth, leftExtension, pixelScale) = (
                marks.template,
                marks.page,
                marks.baseWidth,
                marks.leftExtension,
                marks.pixelScale
            )
            self.page = page
            self.appearance = appearance
            let key = TileKey(template: template, pixelScale: pixelScale, line: appearance.line)
            if tileKey != key {
                tileKey = key
                let tile = Self.tile(for: template, pixelScale: pixelScale, line: appearance.line)
                pattern.backgroundColor = tile.map { UIColor(patternImage: $0).cgColor }
            }
            summaryRule.backgroundColor = appearance.line.cgColor
            seam.backgroundColor = appearance.line.cgColor
            // Marks in page coordinates, spanning more paper than a grab can add either side.
            layoutMarks(template, span: SideGrab.maxExtensionFactor * baseWidth + page.width, leftExtension: leftExtension)
        }

        private func layoutMarks(_ template: PageTemplate, span: CGFloat, leftExtension: CGFloat) {
            let height = page.height
            switch template {
            case .blank:
                pattern.isHidden = true
                summaryRule.isHidden = true
            case let .lined(spacing):
                let s = Self.spacing(spacing)
                pattern.isHidden = false
                summaryRule.isHidden = true
                pattern.frame = CGRect(
                    x: -span, y: TemplateGeometry.top - s / 2, width: 2 * span + page.width, height: height - TemplateGeometry.top
                )
            case let .dotted(spacing), let .grid(spacing):
                let s = Self.spacing(spacing)
                pattern.isHidden = false
                summaryRule.isHidden = true
                // Columns sit at x ≡ leftExtension (mod s); the tile's mark is at its center.
                var phase = leftExtension.truncatingRemainder(dividingBy: s)
                if phase < 0 {
                    phase += s
                }
                let x = phase - s / 2 - (span / s).rounded(.up) * s
                pattern.frame = CGRect(x: x, y: s / 2, width: (2 * span / s).rounded(.up) * s + page.width, height: height - s)
            case .cornell:
                let s = TemplateGeometry.cornellSpacing
                let summary = max(height - TemplateGeometry.cornellSummary, TemplateGeometry.top)
                pattern.isHidden = false
                summaryRule.isHidden = false
                pattern.frame = CGRect(
                    x: -span, y: TemplateGeometry.top - s / 2, width: 2 * span + page.width, height: summary - TemplateGeometry.top
                )
                summaryRule.frame = CGRect(
                    x: -span, y: summary - TemplateGeometry.lineWidth / 2, width: 2 * span + page.width, height: TemplateGeometry.lineWidth
                )
            }
        }

        /// Shows `extent` points of paper added on `side` (negative: taken away) beside the page.
        func place(side: PageSide, extent: CGFloat, hairline: CGFloat) {
            guard let appearance else { return }
            let added = extent > 0
            let width = abs(extent)
            let x: CGFloat = switch (side, added) {
            case (.left, true): -width
            case (.left, false): 0
            case (.right, true): page.width
            case (.right, false): page.width - width
            }
            backgroundColor = added ? appearance.paper : appearance.desk
            pattern.isHidden = !added || pattern.backgroundColor == nil
            summaryRule.isHidden = !added || summaryRule.isHidden
            seam.isHidden = !added
            frame = CGRect(x: page.minX + x, y: page.minY, width: width, height: page.height)
            bounds = CGRect(x: x, y: 0, width: width, height: page.height)
            let seamX = side == .left ? -hairline : page.width
            seam.frame = CGRect(x: seamX, y: 0, width: hairline, height: page.height)
        }

        private static func spacing(_ spacing: Float) -> CGFloat {
            spacing.isFinite ? CGFloat(max(spacing, 4)) : 24
        }

        /// One tile of the template's marks, the mark centered, at `pixelScale` px/pt.
        static func tile(for template: PageTemplate, pixelScale: CGFloat, line: UIColor) -> UIImage? {
            let s: CGFloat
            switch template {
            case .blank: return nil
            case let .lined(spacing), let .dotted(spacing), let .grid(spacing): s = Self.spacing(spacing)
            case .cornell: s = TemplateGeometry.cornellSpacing
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = pixelScale
            format.opaque = false
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: format).image { context in
                let cg = context.cgContext
                cg.setFillColor(line.cgColor)
                let w = TemplateGeometry.lineWidth
                let r = TemplateGeometry.dotRadius
                switch template {
                case .lined, .cornell:
                    cg.fill(CGRect(x: 0, y: s / 2 - w / 2, width: s, height: w))
                case .grid:
                    cg.fill(CGRect(x: 0, y: s / 2 - w / 2, width: s, height: w))
                    cg.fill(CGRect(x: s / 2 - w / 2, y: 0, width: w, height: s))
                case .dotted:
                    cg.fillEllipse(in: CGRect(x: s / 2 - r, y: s / 2 - r, width: 2 * r, height: 2 * r))
                case .blank:
                    break
                }
            }
        }
    }
#endif
