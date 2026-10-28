import DesignSystem
import SwiftUI
import UIKit

/// Window-wide chrome layout (#118): compact chrome on iPhone and in iPad windows under 600 pt wide, and the
/// room iPadOS windowing's window controls (close · minimize · zoom, top leading corner) take from the chrome.
struct ChromeLayout: Equatable {
    /// Compact chrome: back · title and pages · ⋯ on top, a floating tools bar at the bottom, folders in a sheet.
    var isCompact = false
    /// Window controls, beyond the safe area; zero when none show (full screen, iPhone).
    var windowControls = WindowControls()

    static let compactWidth: CGFloat = 600

    /// Library margin: tighter in compact windows.
    var margin: CGFloat {
        isCompact ? 20 : Tokens.Spacing.libraryMargin
    }
}

/// How far chrome hugging the top leading corner moves to clear the window controls: sideways for a top row
/// (`leading`), down for something at the leading edge (`top`).
struct WindowControls: Equatable {
    var leading: CGFloat = 0
    var top: CGFloat = 0
}

extension EnvironmentValues {
    @Entry var chromeLayout = ChromeLayout()
}

extension View {
    /// Measures the window (width, window controls) and publishes ``ChromeLayout`` to the views below.
    func readsChromeLayout() -> some View {
        modifier(ChromeLayoutReader())
    }
}

private struct ChromeLayoutReader: ViewModifier {
    @State private var width: CGFloat = 0
    @State private var controls = WindowControls()
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .background {
                WindowControlsProbe { controls = $0 }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .environment(\.chromeLayout, ChromeLayout(isCompact: isCompact, windowControls: controls))
    }

    private var isCompact: Bool {
        LaunchOptions.forcesCompactChrome
            || UIDevice.current.userInterfaceIdiom == .phone
            || sizeClass == .compact
            || (width > 0 && width < ChromeLayout.compactWidth)
    }
}

/// A window-filling UIView reading UIKit's corner-adapted safe area (iPadOS 26), which grows past the window
/// controls: sideways with horizontal adaptation, down with vertical. SwiftUI has no equivalent.
private struct WindowControlsProbe: UIViewRepresentable {
    let onChange: (WindowControls) -> Void

    func makeUIView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context _: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((WindowControls) -> Void)?
        private var reported: WindowControls?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // iPadOS windowing scales an app down instead of narrowing it past its minimum size; compact
            // chrome needs the real narrow width.
            window?.windowScene?.sizeRestrictions?.minimumSize = Self.minimumWindow
            report()
        }

        private static let minimumWindow = CGSize(width: 320, height: 480)

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let safe = directionalEdgeInsets(for: .safeArea())
            let sideways = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
            let down = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .vertical))
            let controls = WindowControls(
                leading: max(sideways.leading - safe.leading, 0).rounded(.up),
                top: max(down.top - safe.top, 0).rounded(.up)
            )
            guard controls != reported else { return }
            reported = controls
            // Not mid-layout: the change re-renders SwiftUI.
            Task { @MainActor [weak self] in self?.onChange?(controls) }
        }
    }
}
