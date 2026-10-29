import DesignSystem
import SwiftUI
import UIKit

/// "Continue" card: `cover.heic` when the notebook has one (§5.5), else a paper preview, + meta.
struct RecentCard: View {
    let notebook: NotebookSummary
    let zoom: Namespace.ID
    /// Open as an editor tab (#191): the meta line says so.
    var isOpen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                PagePreview(notebook: notebook)
                    .overlay {
                        if let url = notebook.coverThumbnail {
                            ThumbnailImage(url: url, version: notebook.coverVersion ?? notebook.modifiedAt)
                        }
                    }
                    .aspectRatio(Tokens.Size.recentCard.width / Tokens.Size.recentCard.height, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Tokens.Size.recentRadius))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    .shadow(Tokens.Shadows.thumb)
                    .matchedTransitionSource(id: EditorRoute.TransitionID(id: notebook.id, source: .recent), in: zoom) {
                        $0.clipShape(.rect(cornerRadius: Tokens.Size.recentRadius))
                    }
                Text(notebook.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(2)
                    .padding(.top, 12)
                Text(EditedLabel.recent(notebook, isOpen: isOpen))
                    .font(.meta)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(2)
                    .padding(.top, 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notebook.title)
        .accessibilityValue(EditedLabel.recent(notebook, isOpen: isOpen))
        .accessibilityHint("Opens the notebook")
        .accessibilityIdentifier("recent-\(notebook.title)")
    }
}

/// Top of page 1, zoomed in so the "handwriting" reads like the mock's previews.
struct PagePreview: View {
    let notebook: NotebookSummary

    var body: some View {
        let paper = notebook.theme.style
        GeometryReader { proxy in
            let scale = proxy.size.width / 500
            ZStack(alignment: .topLeading) {
                Rectangle().fill(paper.paper.color)
                PaperPatternView(notebook.paper.pattern, color: paper.templateLine.color, spacing: Tokens.Size.templateSpacing * scale)
                if let ink = notebook.sampleInk {
                    Canvas { context, _ in
                        context.translateBy(x: -30 * scale, y: -26 * scale)
                        context.scaleBy(x: scale, y: scale)
                        SampleInk.draw(ink, page: 0, paper: paper, in: context)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A thumbnail file decoded off the main thread; transparent until ready, so the view under it is the
/// placeholder (§1.4: no spinners).
struct ThumbnailImage: View {
    let url: URL
    /// Changes when the file may have changed (e.g. the notebook's modified date).
    let version: Date
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: ThumbnailCache.Key(url: url, version: version)) {
                let key = ThumbnailCache.Key(url: url, version: version)
                let loaded = await ThumbnailCache.shared.image(for: key)
                withAnimation(.easeOut(duration: 0.12)) { image = loaded }
            }
    }
}

/// Decoded thumbnails, keyed by file + version. Decodes on the actor, never on main.
actor ThumbnailCache {
    struct Key: Hashable {
        let url: URL
        let version: Date
    }

    static let shared = ThumbnailCache()
    private var images: [Key: UIImage] = [:]

    func image(for key: Key) -> UIImage? {
        if let image = images[key] {
            return image
        }
        guard let image = UIImage(contentsOfFile: key.url.path(percentEncoded: false))?.preparingForDisplay() else { return nil }
        if images.count > 64 {
            images.removeAll()
        }
        images[key] = image
        return image
    }
}

/// Covers grid cell: physical cover + title + page count.
struct CoverTile: View {
    let notebook: NotebookSummary
    let folder: String?
    let zoom: Namespace.ID
    /// Narrower in compact windows (#118); the cover scales with it.
    var width = Tokens.Size.cover.width
    /// Open as an editor tab (#191): the meta line says so.
    var isOpen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                NotebookCover(title: notebook.title, caption: folder, color: notebook.cover.style, width: width)
                    .matchedTransitionSource(id: EditorRoute.TransitionID(id: notebook.id, source: .cover), in: zoom) {
                        $0.clipShape(.rect(cornerRadius: Tokens.Radius.coverEdge))
                    }
                Text(notebook.title)
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    // Narrow compact covers: one line, else long words break mid-word.
                    .lineLimit(width < Tokens.Size.cover.width ? 1 : 2)
                    .padding(.top, 12)
                Text(EditedLabel.pages(notebook.pageCount, isOpen: isOpen))
                    .font(.meta)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .padding(.top, 3)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notebook.title)
        .accessibilityValue([folder, EditedLabel.pages(notebook.pageCount, isOpen: isOpen)].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Opens the notebook")
        .accessibilityIdentifier("cover-\(notebook.title)")
    }
}

/// Gentle press-in for cards and covers.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// "Edited 2 min ago · 11 pages", "Yesterday · 4 pages", "Mon · 31 pages"; "Open · 11 pages" for a notebook
/// that is an editor tab (#191).
enum EditedLabel {
    static func recent(_ notebook: NotebookSummary, now: Date = Date(), isOpen: Bool = false) -> String {
        isOpen ? pages(notebook.pageCount, isOpen: true) : "\(edited(notebook.modifiedAt, now: now)) · \(pages(notebook.pageCount))"
    }

    static func notebooks(_ count: Int) -> String {
        count == 1 ? "1 notebook" : "\(count) notebooks"
    }

    static func pages(_ count: Int, isOpen: Bool = false) -> String {
        let pages = count == 1 ? "1 page" : "\(count) pages"
        return isOpen ? "Open · \(pages)" : pages
    }

    static func edited(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return "Edited just now"
        }
        if seconds < 3600 {
            return "Edited \(Int(seconds / 60)) min ago"
        }
        if calendar.isDateInToday(date) {
            return "Edited \(Int(seconds / 3600)) h ago"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if seconds < 6 * 86400 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
