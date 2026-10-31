import DesignSystem
import SwiftUI

/// Settings (#228 mock 02): a full-screen page from the library gear or the editor's ⋯ menu. One centred column
/// under a serif title; each setting is a row with a small looping demo of what it does, its name, one plain
/// sentence and its control. A `NavigationStack`, so Sync › Devices pushes inside it (#225).
struct SettingsView: View {
    /// `UserDefaults` key of "Tap to undo" (#121): two fingers undo, three redo, on the canvas.
    static let tapToUndoKey = "tapToUndo"
    /// `UserDefaults` key of "Hold to snap shapes" (#165).
    static let snapsShapesKey = "snapsShapes"
    /// `UserDefaults` key of "Hold to erase" (#211).
    static let holdsToEraseKey = "holdsToErase"
    /// `UserDefaults` key of "New pages" (#172).
    static let newPagesKey = "newPages"
    /// `UserDefaults` key of "Hide status bar" (#191).
    static let hidesStatusBarKey = "hidesStatusBar"
    /// The column's width on a wide screen.
    private static let columnWidth: CGFloat = 660

    /// DEBUG: opens the DesignSystem gallery.
    let showsGallery: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss
    @Environment(SyncModel.self) private var sync: SyncModel?
    @State private var path: [SettingsRoute] = []
    @AppStorage(tapToUndoKey) private var tapToUndo = true
    @AppStorage(snapsShapesKey) private var snapsShapes = true
    @AppStorage(holdsToEraseKey) private var holdsToErase = true
    @AppStorage(newPagesKey) private var newPages = NewPages.manual
    @AppStorage(hidesStatusBarKey) private var hidesStatusBar = false

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                form
                    .contentMargins(
                        .horizontal, max(Tokens.Spacing.xl, (proxy.size.width - Self.columnWidth) / 2), for: .scrollContent
                    )
            }
            .background(Tokens.Colors.libraryBackground)
            .overlay(alignment: .topLeading) { closeButton }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsRoute.self) { _ in
                if let sync {
                    DevicesView(sync: sync)
                }
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.leading, Tokens.Spacing.xxl)
        .padding(.top, Tokens.Spacing.l)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("closeSettings")
    }

    private var form: some View {
        Form {
            Section {
                Text("Settings")
                    .font(.libraryTitle)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 64, leading: Tokens.Spacing.xs, bottom: 0, trailing: 0))
            }
            Section("Writing") {
                SettingRow(.tapToUndo, "Tap to undo", "Tap with two fingers to undo, three to redo.") {
                    Toggle("Tap to undo", isOn: $tapToUndo)
                        .accessibilityIdentifier("tapToUndo")
                }
                SettingRow(.snapShapes, "Hold to snap shapes", "Hold the Pencil still at the end of a stroke to make it a perfect shape.") {
                    Toggle("Hold to snap shapes", isOn: $snapsShapes)
                        .accessibilityIdentifier("snapsShapes")
                }
                SettingRow(.holdToErase, "Hold to erase", "Touch down and hold the Pencil, then erase until you lift it.") {
                    Toggle("Hold to erase", isOn: $holdsToErase)
                        .accessibilityIdentifier("holdsToErase")
                }
            }
            Section("Pages") {
                SettingRow(.newPages, "New pages", "Manual: tap + under the last page. Automatic: a blank page is always waiting.") {
                    Picker("New pages", selection: $newPages) {
                        Text("Manual").tag(NewPages.manual)
                        Text("Automatic").tag(NewPages.automatic)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("newPages")
                }
            }
            Section("Display") {
                SettingRow(.hideStatusBar, "Hide status bar", "Hides the time and battery everywhere in Notespace.") {
                    Toggle("Hide status bar", isOn: $hidesStatusBar)
                        .accessibilityIdentifier("hidesStatusBar")
                }
            }
            if let sync {
                SyncSettingsSection(sync: sync)
            }
            #if DEBUG
                Section("Developer") {
                    if let showsGallery {
                        Button("Design System gallery") {
                            dismiss()
                            showsGallery.wrappedValue = true
                        }
                    }
                }
            #endif
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// One setting: its demo, name, one sentence, and its control (a toggle's own label is hidden; the name says it).
struct SettingRow<Control: View>: View {
    private let demo: SettingDemo.Kind
    private let title: String
    private let detail: String
    private let control: Control

    init(_ demo: SettingDemo.Kind, _ title: String, _ detail: String, @ViewBuilder control: () -> Control) {
        self.demo = demo
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xl) {
            SettingDemo(kind: demo)
                .frame(width: 134, height: 86)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 16.5, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                Text(detail)
                    .scaledFont(size: 14)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Spacing.m)
            control
                .labelsHidden()
        }
        .padding(.vertical, Tokens.Spacing.xs)
    }
}

/// How pages are added at the end of a notebook (#172).
enum NewPages: String {
    /// The add-page button under the last page.
    case manual
    /// A blank page always waits after the last page with content.
    case automatic
}
