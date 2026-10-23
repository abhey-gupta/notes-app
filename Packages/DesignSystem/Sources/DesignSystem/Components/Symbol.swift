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

    public var name: String {
        rawValue
    }
}
