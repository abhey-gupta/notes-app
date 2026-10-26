import DesignSystem
import Observation
import SwiftUI
import Tools

/// The editor's arrowless glass cards (#126): ⋯ (``PagePopover``), Share (``SharePopover``) and quick colors
/// (``QuickColorsEditor``). One at a time; each grows out of its button and morphs back into it on close
/// (Reduce Motion: a fade). ``ToolbarHost`` draws them (``ChromeCardLayer``); buttons open them through the
/// environment and report their frames here.
@MainActor @Observable
final class ChromeCards {
    enum Kind: Hashable {
        case more, share, quickColors
    }

    /// Card the user has open; `nil` once closing starts.
    private(set) var kind: Kind?
    /// Card on screen, kept while it morphs back into its button.
    private(set) var shown: Kind?
    /// Grown to full size; `false` while it sits on its button (just inserted, or closed).
    private(set) var isOpen = false
    /// Button each card grows from, in ``ToolbarHost``'s chrome space.
    private(set) var sources: [Kind: CGRect] = [:]
    var reduceMotion = false
    /// The share sheet for an exported PDF, anchored to the Share button (⋯ in compact chrome).
    @ObservationIgnored let presenter = ActivityPresenter()
    /// Bumped per morph so a stale close completion doesn't remove a newer card.
    @ObservationIgnored private var generation = 0

    func toggle(_ kind: Kind) {
        if self.kind == kind {
            close()
        } else {
            open(kind)
        }
    }

    /// Opens `kind`; another open card morphs back into its button first.
    func open(_ kind: Kind) {
        guard self.kind != kind else { return }
        self.kind = kind
        if shown == nil {
            insert(kind)
        } else if shown == kind {
            // Reopened while still closing: grow back out.
            generation += 1
            withAnimation(Tokens.Motion.card) { isOpen = true }
        } else {
            collapse()
        }
    }

    func close() {
        guard kind != nil else { return }
        kind = nil
        collapse()
    }

    /// The inserted card has laid out on its button: grow it.
    func appeared() {
        guard let shown, shown == kind, !isOpen else { return }
        withAnimation(Tokens.Motion.card) { isOpen = true }
    }

    func setSource(_ frame: CGRect, for kind: Kind) {
        if sources[kind] != frame {
            sources[kind] = frame
        }
    }

    private func insert(_ kind: Kind) {
        if reduceMotion {
            withAnimation(Tokens.Motion.reducedMorph) {
                shown = kind
                isOpen = true
            }
        } else {
            isOpen = false
            shown = kind
        }
    }

    /// Morphs the shown card back into its button, then removes it and shows `kind`, if any.
    private func collapse() {
        if reduceMotion {
            withAnimation(Tokens.Motion.reducedMorph) {
                shown = nil
                isOpen = false
            }
            if let kind {
                insert(kind)
            }
            return
        }
        generation += 1
        let current = generation
        withAnimation(Tokens.Motion.card) {
            isOpen = false
        } completion: { [weak self] in
            guard let self, generation == current else { return }
            withAnimation(Tokens.Motion.cardFade) { shown = nil }
            if let kind {
                insert(kind)
            }
        }
    }
}

/// Where a card sits once open: its `anchor` unit point at `point`, in the chrome's space.
struct ChromeCardPlacement {
    var point: CGPoint
    var anchor: UnitPoint

    /// ⋯ and Share: just below the pages capsule, trailing edges aligned. Quick colors: beside ⌄ (`button`),
    /// across the toolbar from its dock edge.
    init(_ kind: ChromeCards.Kind?, pages: CGRect, toolbar: CGRect, button: CGRect?, dock: ToolbarDock) {
        let gap = Tokens.Spacing.cardGap
        guard kind == .quickColors, let button else {
            (point, anchor) = (CGPoint(x: pages.maxX, y: pages.maxY + gap), .topTrailing)
            return
        }
        (point, anchor) = switch dock {
        case .top: (CGPoint(x: button.midX, y: toolbar.maxY + gap), .top)
        case .bottom: (CGPoint(x: button.midX, y: toolbar.minY - gap), .bottom)
        case .left: (CGPoint(x: toolbar.maxX + gap, y: button.midY), .leading)
        case .right: (CGPoint(x: toolbar.minX - gap, y: button.midY), .trailing)
        }
    }
}

/// What each editor card holds.
struct EditorCard: View {
    let kind: ChromeCards.Kind
    let tools: ToolState
    let state: EditorState
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    let page: (current: Int, total: Int)

    @Environment(ChromeCards.self) private var cards
    @Environment(\.isCompactLayout) private var isCompactLayout

    var body: some View {
        switch kind {
        case .more:
            PagePopover(
                tools: tools, paper: $paper, pattern: $pattern,
                onShare: isCompactLayout ? { cards.open(.share) } : nil
            ) {
                cards.close()
                state.enterFocus()
            }
        case .share:
            SharePopover(state: state, page: page, isNight: paper == .night) { url in
                cards.close()
                cards.presenter.share(url)
            }
        case .quickColors:
            QuickColorsEditor(tools: tools, paper: paper)
        }
    }
}

/// The open card above a scrim that eats any tap outside it (nothing draws from that tap) and closes it.
/// Escape and the VoiceOver escape gesture close it too.
struct ChromeCardLayer<Card: View>: View {
    let cards: ChromeCards
    let placement: ChromeCardPlacement
    @ViewBuilder let card: (ChromeCards.Kind) -> Card

    var body: some View {
        ZStack {
            if cards.kind != nil {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: cards.close)
                    .padding(.horizontal, -Tokens.Spacing.chromeInset)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                Button("Close", action: cards.close)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let shown = cards.shown {
                CardPlacementLayout(source: cards.sources[shown] ?? .zero, placement: placement, isOpen: cards.isOpen) {
                    ChromeCard(isOpen: cards.isOpen, source: cards.sources[shown] ?? .zero, anchor: placement.anchor) {
                        card(shown)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityAction(.escape, cards.close)
                    }
                    .onAppear(perform: cards.appeared)
                }
                .id(shown)
                .transition(cards.reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
            }
        }
    }
}

/// Rounded glass card in the paper's chrome material (#122). Closed, it is its button's size with the content
/// faded out, so opening reads as the glass growing out of the button.
private struct ChromeCard<Content: View>: View {
    let isOpen: Bool
    let source: CGRect
    let anchor: UnitPoint
    @ViewBuilder let content: Content

    @Environment(\.chromeAppearance) private var appearance

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: isOpen ? Tokens.Radius.capsule : min(source.width, source.height) / 2,
            style: .continuous
        )
        GlassEffectContainer {
            content
                .fixedSize()
                .opacity(isOpen ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(anchor))
                .clipShape(shape)
                .background(appearance?.cardBacking ?? .clear, in: shape)
                .chromeGlass(in: shape)
        }
        .dynamicTypeSize(...DynamicTypeSize.chromeLimit)
    }
}

/// Places the card: on its button while closed, else per ``ChromeCardPlacement``, kept inside the chrome.
private struct CardPlacementLayout: Layout {
    let source: CGRect
    let placement: ChromeCardPlacement
    let isOpen: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let card = subviews.first else { return }
        guard isOpen else {
            card.place(at: bounds.origin + CGSize(width: source.minX, height: source.minY), proposal: ProposedViewSize(source.size))
            return
        }
        let size = card.sizeThatFits(.unspecified)
        let x = placement.point.x - size.width * placement.anchor.x
        let y = placement.point.y - size.height * placement.anchor.y
        let origin = CGPoint(
            x: min(max(x, 0), max(bounds.width - size.width, 0)),
            y: min(max(y, 0), max(bounds.height - size.height, 0))
        )
        card.place(at: bounds.origin + CGSize(width: origin.x, height: origin.y), proposal: ProposedViewSize(size))
    }
}

private extension Alignment {
    init(_ point: UnitPoint) {
        let horizontal: HorizontalAlignment = point.x < 0.5 ? .leading : point.x > 0.5 ? .trailing : .center
        let vertical: VerticalAlignment = point.y < 0.5 ? .top : point.y > 0.5 ? .bottom : .center
        self.init(horizontal: horizontal, vertical: vertical)
    }
}

private struct ChromeCardsHost: ViewModifier {
    let cards: ChromeCards
    let closing: Bool
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(cards)
            .onChange(of: reduceMotion, initial: true) { cards.reduceMotion = $1 }
            .onChange(of: cards.kind) {
                if $1 != nil {
                    onOpen()
                }
            }
            .onChange(of: closing) {
                if $1 {
                    cards.close()
                }
            }
    }
}

extension View {
    /// Hands `cards` to the chrome; the open card closes when `closing` turns true, and `onOpen` runs when one opens.
    func chromeCards(_ cards: ChromeCards, closingOn closing: Bool, onOpen: @escaping () -> Void) -> some View {
        modifier(ChromeCardsHost(cards: cards, closing: closing, onOpen: onOpen))
    }

    /// Reports this button's frame as the place `kind`'s card grows from.
    func chromeCardSource(_ kind: ChromeCards.Kind, in cards: ChromeCards) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ToolbarHost.space)) } action: { cards.setSource($0, for: kind) }
    }
}
