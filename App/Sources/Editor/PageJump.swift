import DesignSystem
import InkModel
import Observation
import SwiftUI

/// Go to page (#214): a header button that widens into "Page [ _ ] of N · Go". Return or Go jumps
/// (out-of-range numbers clamp to the first or last page) and folds it back; so do Esc and the field
/// losing focus. On a hardware keyboard a digit opens it with that digit typed, and so does ⌘G.
struct PageJumpControl: View {
    let count: Int
    @Binding var isOpen: Bool
    /// Page index (0-based) to jump to.
    let onJump: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        GlassCapsule(
            height: Tokens.Size.focusPillHeight,
            leading: isOpen ? Tokens.Spacing.l : Tokens.Spacing.xs,
            trailing: Tokens.Spacing.xs,
            spacing: Tokens.Spacing.s
        ) {
            if isOpen {
                field
            } else {
                ToolButton(.goToPage, "Go to page", size: Tokens.Size.compactToolButton) { open() }
                    .keyboardShortcut("g", modifiers: .command)
                    .accessibilityIdentifier("pagesGoTo")
            }
        }
        .background {
            if !isOpen {
                digitShortcuts
            }
        }
        .onChange(of: isOpen) { _, isOpen in
            if !isOpen {
                isFocused = false
            }
        }
    }

    private var field: some View {
        Group {
            Text("Page")
                .foregroundStyle(Tokens.Colors.textSecondary)
                .accessibilityHidden(true)
            TextField("", text: $text)
                .focused($isFocused)
                .keyboardType(.numberPad)
                .submitLabel(.go)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textPrimary)
                .frame(width: fieldWidth, height: 28)
                .background(Tokens.Colors.field, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.Colors.selection, lineWidth: 1.5)
                }
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onChange(of: text) { _, new in
                    let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(String(count).count))
                    if digits != new {
                        text = digits
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        close()
                    }
                }
                .onAppear { FrameAfter.next { isFocused = true } }
                .accessibilityLabel("Page number, of \(count)")
                .accessibilityIdentifier("pagesGoToField")
            Text("of \(count)")
                .foregroundStyle(Tokens.Colors.textSecondary)
                .monospacedDigit()
                .accessibilityHidden(true)
            Button(action: submit) {
                Text("Go")
                    .foregroundStyle(.white)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .frame(height: 32)
                    .background(Tokens.Colors.selection, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pagesGoToGo")
        }
        .scaledFont(size: 14.5, weight: .medium)
    }

    /// Bare digit keys (hardware keyboard) open the field with that digit typed.
    private var digitShortcuts: some View {
        ZStack {
            ForEach(0 ..< 10, id: \.self) { digit in
                Button("Go to page \(digit)…") { open(typing: "\(digit)") }
                    .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: [])
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Wide enough for the notebook's largest page number.
    private var fieldWidth: CGFloat {
        CGFloat(max(2, String(count).count)) * 11 + 20
    }

    private func open(typing digit: String = "") {
        text = digit
        withAnimation(reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.morph) { isOpen = true }
    }

    private func close() {
        guard isOpen else { return }
        withAnimation(reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.morph) { isOpen = false }
    }

    private func submit() {
        let index = PageJump.index(for: text, count: count)
        close()
        if let index {
            onJump(index)
        }
    }
}

/// The grid's side of a jump: scrolls the page to the middle, then lifts it with a halo that settles
/// and fades (`PageThumb.halo`). A new jump cancels the one in flight.
@MainActor
@Observable
final class PageArrival {
    /// The page just jumped to, haloed while it settles.
    private(set) var page: PageID?
    private(set) var isLifted = false
    @ObservationIgnored var proxy: ScrollViewProxy?
    @ObservationIgnored private var task: Task<Void, Never>?

    func jump(to id: PageID, number: Int, reduceMotion: Bool) {
        guard let proxy else { return }
        task?.cancel()
        task = Task {
            if reduceMotion {
                proxy.scrollTo(id, anchor: .center)
                withAnimation(Tokens.Motion.reducedMorph) { page = id }
            } else {
                withAnimation(PageJump.scroll) { proxy.scrollTo(id, anchor: .center) }
                guard await Self.pause(PageJump.scrollDuration) else { return }
                withAnimation(PageJump.lift) {
                    page = id
                    isLifted = true
                }
                guard await Self.pause(PageJump.liftDuration) else { return }
                withAnimation(PageJump.settle) { isLifted = false }
            }
            AccessibilityNotification.Announcement("Page \(number)").post()
            guard await Self.pause(PageJump.haloDuration) else { return }
            withAnimation(PageJump.fade) { page = nil }
        }
    }

    /// False once the jump is cancelled.
    private static func pause(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }

    func cancel() {
        task?.cancel()
        page = nil
        isLifted = false
    }
}

enum PageJump {
    /// The page index typed `text` (1-based) lands on, clamped to the notebook; nil when nothing was typed.
    static func index(for text: String, count: Int) -> Int? {
        guard count > 0, let number = Int(text) else { return nil }
        return min(max(number, 1), count) - 1
    }

    /// The grid's scroll to the page, then the cell's lift-and-halo once it's there.
    static let scroll: Animation = .smooth(duration: 0.5)
    static let scrollDuration: Duration = .milliseconds(400)
    static let lift: Animation = .snappy(duration: 0.2)
    static let liftDuration: Duration = .milliseconds(300)
    static let settle: Animation = .smooth(duration: 0.35)
    static let haloDuration: Duration = .milliseconds(1100)
    static let fade: Animation = .easeOut(duration: 0.6)
}
