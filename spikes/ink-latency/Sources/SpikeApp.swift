import Perf
import SwiftUI
import UIKit

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup {
            RootRepresentable()
                .ignoresSafeArea()
                .perfHUD()
        }
    }
}

struct RootRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> RootViewController {
        RootViewController()
    }

    func updateUIViewController(_: RootViewController, context _: Context) {}
}

/// Segmented control switching PencilKit / Metal / 100 stacked PencilKit pages, plus a stats bar.
final class RootViewController: UIViewController {
    private let screens = UISegmentedControl(items: ["PencilKit", "Metal", "PencilKit · 100 pages"])
    private let container = UIView()
    private let bar = UIStackView()
    private var current: (UIViewController & SpikeScreen)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.93, alpha: 1)
        screens.selectedSegmentIndex = 0
        screens.addAction(UIAction { [weak self] _ in self?.show(self?.screens.selectedSegmentIndex ?? 0) }, for: .valueChanged)

        bar.axis = .horizontal
        bar.spacing = 12
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        bar.backgroundColor = .secondarySystemBackground
        let top = UIStackView(arrangedSubviews: [screens, UIView(), bar])
        top.axis = .vertical
        top.spacing = 0
        top.alignment = .fill

        for v in [container, top] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // `-screen 1` launches on the Metal screen (handy for simulator smoke checks).
        let initial = min(max(UserDefaults.standard.integer(forKey: "screen"), 0), 2)
        screens.selectedSegmentIndex = initial
        show(initial)
    }

    private func show(_ index: Int) {
        current?.willMove(toParent: nil)
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        let next: UIViewController & SpikeScreen = switch index {
        case 1: MetalScreen()
        case 2: StackedPagesScreen()
        default: PencilKitScreen()
        }
        addChild(next)
        next.view.frame = container.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(next.view)
        next.didMove(toParent: self)
        current = next
        for v in bar.arrangedSubviews {
            v.removeFromSuperview()
        }
        for v in next.toolbarItems() {
            bar.addArrangedSubview(v)
        }
    }
}

/// A spike screen contributes controls to the shared bar.
@MainActor
protocol SpikeScreen {
    func toolbarItems() -> [UIView]
}

@MainActor
func spikeButton(_ title: String, _ action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.gray()
    config.title = title
    config.buttonSize = .small
    return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
}

@MainActor
func spikeLabel() -> UILabel {
    let label = UILabel()
    label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    label.numberOfLines = 2
    return label
}
