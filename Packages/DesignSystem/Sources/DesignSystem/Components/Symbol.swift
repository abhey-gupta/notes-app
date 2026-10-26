/// SF Symbols used by chrome, chosen to match the mock's line icons.
public enum Symbol: String, CaseIterable, Sendable {
    case back = "chevron.backward"
    case disclosure = "chevron.down"
    case pen = "pencil"
    case highlighter
    case eraser
    case lasso
    case undo = "arrow.uturn.backward"
    case redo = "arrow.uturn.forward"
    case pages = "square.grid.2x2"
    case share = "square.and.arrow.up"
    case more = "ellipsis"
    case search = "magnifyingglass"
    case settings = "gearshape"
    case add = "plus"
    case focus = "viewfinder"
    case palette = "paintpalette"
    case duplicate = "plus.square.on.square"
    case delete = "trash"
    case sidebar = "sidebar.leading"
    case folder = "folder.fill"
    case allNotebooks = "books.vertical"
    case expand = "chevron.forward"

    public var name: String {
        rawValue
    }
}
