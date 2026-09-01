import ContainerAPIClient
import Foundation

actor ComposeExitCodes {
    static let shared = ComposeExitCodes()

    private var waits: [String: Task<Int32?, Never>] = [:]
    private var order: [String] = []  // registration order, for eviction

    /// Watches the process until it exits. Entries are capped (oldest dropped)
    /// and displaced tasks are cancelled — best effort only: the underlying XPC
    /// wait ignores cancellation, so a cancelled task still lives until its
    /// process exits; it just stops being tracked here.
    ///
    /// Call BEFORE starting the process: register returns only once the
    /// watcher task is executing, so its wait request is on the wire before
    /// the caller's start request. A wait issued after start races a fast
    /// one-shot — the apiserver reaps the runtime client the moment the init
    /// process exits, and a wait arriving after that errors, losing the code.
    /// (Waits are valid from bootstrap on; they don't need a started process.)
    func register(id: String, process: ClientProcess) async {
        waits[id]?.cancel()
        await withCheckedContinuation { started in
            waits[id] = Task {
                started.resume()
                return try? await process.wait()
            }
        }
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > 64 { waits.removeValue(forKey: order.removeFirst())?.cancel() }
    }

    /// Blocks until the process exits. nil when the id was never registered
    /// (started outside this process, or evicted) or the wait itself failed.
    func exitCode(for id: String) async -> Int32? {
        guard let wait = waits[id] else { return nil }
        return await wait.value
    }
}

// MARK: - Execution
