import SwiftUI

/// Settings popover from the library gear. A `NavigationStack`, so Sync › Devices pushes inside it (#225).
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
            form
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SettingsRoute.self) { _ in
                    if let sync {
                        DevicesView(sync: sync)
                    }
                }
        }
        .frame(width: 340, height: 500)
    }

    private var form: some View {
        Form {
            Section {
                Toggle("Tap to undo", isOn: $tapToUndo)
                    .accessibilityIdentifier("tapToUndo")
                Toggle("Hold to snap shapes", isOn: $snapsShapes)
                    .accessibilityIdentifier("snapsShapes")
                Toggle("Hold to erase", isOn: $holdsToErase)
                    .accessibilityIdentifier("holdsToErase")
            } header: {
                Text("Gestures")
            } footer: {
                Text(
                    """
                    Tap with two fingers to undo, three to redo. Hold the Pencil still at a stroke's end to make it a perfect \
                    shape, or where it touches down to erase until you lift it.
                    """
                )
            }
            Section {
                Picker("New pages", selection: $newPages) {
                    Text("Manual").tag(NewPages.manual)
                    Text("Automatic").tag(NewPages.automatic)
                }
                .accessibilityIdentifier("newPages")
            } header: {
                Text("Pages")
            } footer: {
                Text("Automatic adds a page when you write on the last one.")
            }
            Section {
                Toggle("Hide status bar", isOn: $hidesStatusBar)
                    .accessibilityIdentifier("hidesStatusBar")
            } header: {
                Text("Display")
            } footer: {
                Text("Hides the time and battery everywhere in Notespace.")
            }
            if let sync {
                SyncSettingsSection(sync: sync)
            }
            #if DEBUG
                Section {
                    if let showsGallery {
                        Button("Design System gallery") {
                            dismiss()
                            showsGallery.wrappedValue = true
                        }
                    }
                } header: {
                    Text("Developer")
                }
            #endif
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
    }
}

/// How pages are added at the end of a notebook (#172).
enum NewPages: String {
    /// The add-page button under the last page.
    case manual
    /// A blank page always waits after the last page with content.
    case automatic
}
