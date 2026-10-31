import DesignSystem
import Library
import SwiftUI

/// "Sorted by Recent ⌄": the library's sort, beside the notebooks heading.
struct LibrarySortMenu: View {
    @Binding var sort: LibrarySort

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Recent").tag(LibrarySort.recent)
                Text("Title").tag(LibrarySort.title)
                Text("Created").tag(LibrarySort.created)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Sorted by \(sort.rawValue)")
                Image(systemName: Symbol.disclosure.name)
                    .scaledFont(size: 10, weight: .semibold)
            }
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}
