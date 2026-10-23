import DesignSystem
import SwiftUI

/// Placeholder until the app shell lands (#13).
struct RootView: View {
    #if DEBUG
        @State private var showsGallery = UserDefaults.standard.bool(forKey: "DesignSystemGallery")
    #endif

    var body: some View {
        ZStack {
            Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea()
            VStack(spacing: Tokens.Spacing.xxl) {
                Text("Notespace")
                    .font(.notebookTitle(size: 46))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
                #if DEBUG
                    Button("Design System") { showsGallery = true }
                        .buttonStyle(.glass)
                #endif
            }
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showsGallery) {
            DesignSystemGallery()
        }
        #endif
    }
}

#Preview {
    RootView()
}
