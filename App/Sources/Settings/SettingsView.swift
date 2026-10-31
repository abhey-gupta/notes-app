import DesignSystem
import SwiftUI

/// Settings (#228), in the library's detail area: picked from the Settings row at the foot of the sidebar (or the
/// editor's ⋯ menu, which goes back to the library first). A serif title where the library's sits, then one
/// column of rows; each row has a small looping demo of what the setting does, its name, one plain sentence and
/// its control. Sync › Devices replaces the column in place, with a back button.
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
    /// The column's widest.
    private static let columnWidth: CGFloat = 660

    /// DEBUG: opens the DesignSystem gallery.
    let showsGallery: Binding<Bool>?
    /// Shows the sidebar; nil while it's docked and showing.
    var showSidebar: (() -> Void)?
    /// The header starts at the window's leading edge (no docked sidebar), so it clears the window controls.
    var hugsLeadingEdge = true

    @Environment(SyncModel.self) private var sync: SyncModel?
    @Environment(\.chromeLayout) private var chrome
    @State private var showsDevices = false
    @AppStorage(tapToUndoKey) private var tapToUndo = true
    @AppStorage(snapsShapesKey) private var snapsShapes = true
    @AppStorage(holdsToEraseKey) private var holdsToErase = true
    @AppStorage(newPagesKey) private var newPages = NewPages.manual
    @AppStorage(hidesStatusBarKey) private var hidesStatusBar = false

    var body: some View {
        GeometryReader { proxy in
            Group {
                if showsDevices, let sync {
                    DevicesView(sync: sync)
                } else {
                    form
                }
            }
            // Level with the library's covers; no wider than the column.
            .contentMargins(.leading, chrome.margin, for: .scrollContent)
            .contentMargins(.trailing, max(chrome.margin, proxy.size.width - chrome.margin - Self.columnWidth), for: .scrollContent)
            .scrollContentBackground(.hidden)
        }
        .background { Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea() }
        .safeAreaBar(edge: .top) { header }
        .onChange(of: sync?.folderName) { _, name in
            if name == nil {
                showsDevices = false
            }
        }
    }

    /// Where the library header's title sits: a sidebar (or back) button, then the serif title.
    private var header: some View {
        HStack(spacing: Tokens.Spacing.m) {
            if showsDevices {
                circleButton("Settings", systemImage: "chevron.backward") {
                    withAnimation(.snappy(duration: 0.25)) { showsDevices = false }
                }
                .accessibilityIdentifier("settingsBack")
            } else if let showSidebar {
                circleButton("Show Sidebar", systemImage: "sidebar.leading", action: showSidebar)
                    .accessibilityIdentifier("sidebarButton")
            }
            Text(showsDevices ? "Devices" : "Settings")
                .font(.libraryTitle)
                .tracking(-0.5)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settingsTitle")
            Spacer(minLength: 0)
        }
        .padding(.leading, chrome.margin + (hugsLeadingEdge ? chrome.windowControls.leading : 0))
        .padding(.trailing, chrome.margin)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private func circleButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    private var form: some View {
        Form {
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
                SyncSettingsSection(sync: sync) {
                    withAnimation(.snappy(duration: 0.25)) { showsDevices = true }
                }
            }
            #if DEBUG
                Section("Developer") {
                    if let showsGallery {
                        Button("Design System gallery") {
                            showsGallery.wrappedValue = true
                        }
                    }
                }
            #endif
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
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

extension EnvironmentValues {
    /// Goes back to the library with Settings showing (#228, the editor's ⋯ menu); `nil` in previews.
    @Entry var showSettings: (() -> Void)?
}
