import SwiftUI

#Preview("Library") {
    @Previewable @Namespace var zoom
    @Previewable @State var showsNew = false
    @Previewable @State var pdfImport: PDFImportRequest?
    @Previewable @State var showsSettings = false
    LibraryScreen(
        library: SampleLibrary(), zoom: zoom, tabs: TabsModel(), showsNewNotebook: $showsNew, pdfImport: $pdfImport,
        showsSettings: $showsSettings, showsGallery: nil
    ) { _ in }
}
