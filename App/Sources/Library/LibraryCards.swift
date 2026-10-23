import DesignSystem
import SwiftUI

/// "Continue" card: live-looking page preview (placeholder ink until `cover.heic` thumbnails, §5.5) + meta.
struct RecentCard: View {
    let notebook: NotebookSummary
    let zoom: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                PagePreview(notebook: notebook)
                    .aspectRatio(Tokens.Size.recentCard.width / Tokens.Size.recentCard.height, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Tokens.Size.recentRadius))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    .shadow(Tokens.Shadows.thumb)
                    .matchedTransitionSource(id: EditorRoute.TransitionID(id: notebook.id, source: .recent), in: zoom) {
                        $0.clipShape(.rect(cornerRadius: Tokens.Size.recentRadius))
                    }
                Text(notebook.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 12)
                Text(EditedLabel.recent(notebook))
                    .font(.meta)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
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

/// Covers grid cell: physical cover + title + page count.
struct CoverTile: View {
    let notebook: NotebookSummary
    let folder: String?
    let zoom: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                NotebookCover(title: notebook.title, caption: folder, color: notebook.cover.style)
                    .matchedTransitionSource(id: EditorRoute.TransitionID(id: notebook.id, source: .cover), in: zoom) {
                        $0.clipShape(.rect(cornerRadius: Tokens.Radius.coverEdge))
                    }
                Text(notebook.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 12)
                Text(EditedLabel.pages(notebook.pageCount))
                    .font(.meta)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .padding(.top, 3)
            }
            .frame(width: Tokens.Size.cover.width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
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

/// "Edited 2 min ago · 11 pages", "Yesterday · 4 pages", "Mon · 31 pages".
enum EditedLabel {
    static func recent(_ notebook: NotebookSummary, now: Date = Date()) -> String {
        "\(edited(notebook.modifiedAt, now: now)) · \(pages(notebook.pageCount))"
    }

    static func pages(_ count: Int) -> String {
        count == 1 ? "1 page" : "\(count) pages"
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
