import SwiftUI

/// Placeholder until the app shell lands (#13).
struct RootView: View {
    var body: some View {
        ZStack {
            Color(red: 0.953, green: 0.945, blue: 0.925).ignoresSafeArea()
            Text("Notespace")
                .font(.system(size: 46, weight: .regular, design: .serif))
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: .capsule)
        }
    }
}

#Preview {
    RootView()
}
