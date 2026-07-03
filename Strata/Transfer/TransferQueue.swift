import Foundation

/// Owns the set of in-flight and queued transfers. An actor so the browser UI
/// (main actor) and background transfer tasks can mutate queue state safely.
/// Pause/resume/retry and bandwidth control land on top of this in v1.
actor TransferQueue {
    private(set) var transfers: [Transfer] = []

    func enqueue(_ transfer: Transfer) {
        transfers.append(transfer)
    }

    func update(_ id: UUID, state: TransferState) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
    }

    func remove(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }
}
