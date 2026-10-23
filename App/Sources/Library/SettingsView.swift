import SwiftUI

/// Settings popover from the library gear. Only developer toggles exist on Day 0.
struct SettingsView: View {
    /// DEBUG: opens the DesignSystem gallery.
    let showsGallery: Binding<Bool>?

    #if DEBUG
        @AppStorage(ToolbarDock.defaultsKey) private var dock: ToolbarDock = .top
    #endif
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            #if DEBUG
                Section {
                    Picker("Toolbar dock", selection: $dock) {
                        ForEach(ToolbarDock.allCases) { Text($0.displayName).tag($0) }
                    }
                    if let showsGallery {
                        Button("Design System gallery") {
                            dismiss()
                            showsGallery.wrappedValue = true
                        }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Static dock preview. Drag-to-snap and pinch-to-compact land in #26.")
                }
            #endif
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .frame(width: 340, height: 300)
    }
}
