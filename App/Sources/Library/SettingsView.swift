import SwiftUI

/// Settings popover from the library gear. Only developer toggles exist on Day 0.
struct SettingsView: View {
    /// DEBUG: opens the DesignSystem gallery.
    let showsGallery: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
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
