import Backup
import Foundation

/// Restore (#174, mock 03 and 04): the folder's catalog, each row's state, bringing notebooks back.
extension BackupModel {
    /// Re-reads the folder's `library.json`.
    func loadCatalog() async {
        guard let engine else { return }
        do {
            catalog = try await engine.catalog()
        } catch {
            fail(error)
        }
    }

    /// Backed-up notebooks the library doesn't have, not deleted ones (the fresh-iPad card's count).
    var restorableCount: Int {
        catalog?.notebooks.count { !$0.trashed && rowState($0) == .restorable } ?? 0
    }

    func rowState(_ item: BackupCatalog.Notebook) -> RowState {
        if restored.contains(item.id) {
            return .restored
        }
        if restoring.contains(item.id) {
            return .restoring
        }
        if skipped.contains(item.id) || library.notebook(id: item.id) != nil {
            return .onThisIPad
        }
        return .restorable
    }

    /// Restores `items` one by one; each shows in the library as it lands. Local notebooks are never touched.
    func restore(_ items: [BackupCatalog.Notebook]) async {
        guard let engine, let catalog else { return }
        for item in items where rowState(item) == .restorable {
            restoring.insert(item.id)
            do {
                if try await engine.restore(item, from: catalog) {
                    restored.insert(item.id)
                    await library.reload()
                } else {
                    skipped.insert(item.id)
                }
            } catch {
                fail(error)
            }
            restoring.remove(item.id)
        }
    }

    /// Restore all (the fresh-iPad card, Restore's nav button): every notebook that isn't deleted.
    func restoreAll() async {
        await restore(catalog?.notebooks.filter { !$0.trashed } ?? [])
    }
}
