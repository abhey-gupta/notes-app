import DesignSystem
import Export
import SwiftUI
import UIKit

/// Export PDF (§9, #42), the card the Share button opens (#126): all / current page / range, "Export as shown" on
/// Night, then a determinate progress bar. The finished file goes to the share sheet (``ActivityAnchor``).
struct SharePopover: View {
    let state: EditorState
    /// Current page, 1-based, and the page count.
    let page: (current: Int, total: Int)
    let isNight: Bool
    let onExported: (URL) -> Void

    @State private var scope = Scope.all
    @State private var from = 1
    @State private var to = 1
    @State private var asShown = false
    @State private var progress: Double?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Scope: CaseIterable {
        case all, current, range

        var title: String {
            switch self {
            case .all: "All"
            case .current: "This page"
            case .range: "Range"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export PDF")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(Tokens.Colors.chromeText)
                .padding(.horizontal, Tokens.Spacing.xs)
                .padding(.bottom, 12)
            SegmentedChoice(Scope.allCases, selection: $scope, title: \.title)
                .disabled(progress != nil)
                .accessibilityIdentifier("exportScope")
            if scope == .range {
                rangeRows
            }
            if isNight {
                Toggle("Export as shown", isOn: $asShown)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Tokens.Colors.chromeText)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .padding(.top, 14)
                    .disabled(progress != nil)
            }
            footer
                .padding(.top, 16)
            if let failure {
                Text(failure)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.horizontal, Tokens.Spacing.xs)
            }
        }
        .padding(Tokens.Size.popoverPadding)
        .frame(width: Tokens.Size.popoverWidth * typeSize.chromeScale)
        .onAppear {
            from = page.current
            to = page.total
        }
        .onDisappear { task?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharePopover")
    }

    private var rangeRows: some View {
        VStack(spacing: 6) {
            Stepper("From page \(from)", value: $from, in: 1 ... max(to, 1))
            Stepper("To page \(to)", value: $to, in: from ... max(page.total, from))
        }
        .scaledFont(size: 14, weight: .medium)
        .foregroundStyle(Tokens.Colors.chromeText)
        .monospacedDigit()
        .padding(.horizontal, Tokens.Spacing.xs)
        .padding(.top, 14)
        .disabled(progress != nil)
    }

    @ViewBuilder private var footer: some View {
        if let progress {
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .tint(Tokens.Colors.selection.color)
                    .accessibilityIdentifier("exportProgress")
                Button("Cancel") { task?.cancel() }
                    .buttonStyle(.glass)
            }
        } else {
            Button {
                export()
            } label: {
                Text(exportTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Tokens.Colors.selection.color)
            .fontWeight(.semibold)
            .accessibilityIdentifier("exportButton")
        }
    }

    private var exportTitle: String {
        let count = switch scope {
        case .all: page.total
        case .current: 1
        case .range: to - from + 1
        }
        return count == 1 ? "Export 1 page" : "Export \(count) pages"
    }

    private var selection: PageSelection {
        switch scope {
        case .all: .all
        case .current: .page(page.current - 1)
        case .range: .range(from - 1 ... to - 1)
        }
    }

    private func export() {
        failure = nil
        progress = 0
        let (selection, asShown) = (selection, isNight && asShown)
        task = Task {
            defer {
                progress = nil
                task = nil
            }
            do {
                let url = try await state.exportPDF(selection, asShown) { fraction in
                    Task { @MainActor in progress = max(progress ?? 0, fraction) }
                }
                onExported(url)
            } catch is CancellationError {
                return
            } catch {
                failure = "Couldn’t export. \(error.localizedDescription)"
            }
        }
    }
}

/// Presents the share sheet for an exported file as a popover from the view it backs (the Share button),
/// after any presentation still on screen has gone. Deletes the file's temp directory when the sheet closes.
struct ActivityAnchor: UIViewRepresentable {
    let presenter: ActivityPresenter

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        presenter.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context _: Context) {
        presenter.anchor = view
    }
}

@MainActor
final class ActivityPresenter {
    weak var anchor: UIView?

    func share(_ url: URL) {
        guard let anchor, let root = anchor.window?.rootViewController else {
            Self.discard(url)
            return
        }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor.bounds
        sheet.completionWithItemsHandler = { _, _, _, _ in Self.discard(url) }
        if let dismissing = top.presentedViewController?.transitionCoordinator {
            dismissing.animate(alongsideTransition: nil) { _ in top.present(sheet, animated: true) }
        } else {
            top.present(sheet, animated: true)
        }
    }

    /// Removes the exporter's per-export temp directory.
    private static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
