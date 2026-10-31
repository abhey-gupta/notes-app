import InkModel
import Synchronization

/// Editors opening notebooks vs. the pull writing them (#225), decided under one lock outside the engine's
/// actor: a pull writes a notebook only if no editor is opening it (``beginWrite(_:)``), and an editor opening
/// one that is being written waits for that write (``open(_:)``). So an editor never reads a package half
/// written, and opening never waits behind a pass's other work (the actor may be busy copying blobs).
final class OpenGate: Sendable {
    private struct State {
        var open: Set<NotebookID> = []
        var writing: NotebookID?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Marks `id` open; returns once a write of it under way has finished.
    func open(_ id: NotebookID) async {
        let busy = state.withLock { state in
            state.open.insert(id)
            return state.writing == id
        }
        guard busy else { return }
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                guard state.writing == id else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume {
                continuation.resume()
            }
        }
    }

    func close(_ id: NotebookID) {
        _ = state.withLock { $0.open.remove(id) }
    }

    /// Starts writing `id` unless an editor has it open (then `false`: its changes wait).
    func beginWrite(_ id: NotebookID) -> Bool {
        state.withLock { state in
            guard !state.open.contains(id) else { return false }
            state.writing = id
            return true
        }
    }

    /// The write is done: editors waiting to open go on.
    func endWrite() {
        let waiters = state.withLock { state in
            state.writing = nil
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
