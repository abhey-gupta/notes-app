import SwiftUI

/// Settings popover from the library gear.
struct SettingsView: View {
    /// `UserDefaults` key of "Tap to undo" (#121): two fingers undo, three redo, on the canvas.
    static let tapToUndoKey = "tapToUndo"
    /// `UserDefaults` key of "New pages" (#172).
    static let newPagesKey = "newPages"

    /// DEBUG: opens the DesignSystem gallery.
    let showsGallery: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(tapToUndoKey) private var tapToUndo = true
    @AppStorage(newPagesKey) private var newPages = NewPages.manual

    var body: some View {
        Form {
            Section {
                Toggle("Tap to undo", isOn: $tapToUndo)
                    .accessibilityIdentifier("tapToUndo")
            } header: {
                Text("Gestures")
            } footer: {
                Text("Tap with two fingers to undo, three fingers to redo.")
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
        .frame(width: 340, height: 420)
    }
}

/// How pages are added at the end of a notebook (#172).
enum NewPages: String {
    /// The add-page button under the last page.
    case manual
    /// A blank page always waits after the last page with content.
    case automatic
}
