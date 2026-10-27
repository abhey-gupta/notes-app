import SwiftUI

/// Settings popover from the library gear.
struct SettingsView: View {
    /// `UserDefaults` key of "Tap to undo" (#121): two fingers undo, three redo, on the canvas.
    static let tapToUndoKey = "tapToUndo"

    /// DEBUG: opens the DesignSystem gallery.
    let showsGallery: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(tapToUndoKey) private var tapToUndo = true

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
        .frame(width: 340, height: 300)
    }
}
