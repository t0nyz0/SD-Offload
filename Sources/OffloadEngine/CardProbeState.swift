import Foundation

/// Serial-queue-owned insertion state. Failed probes remain retryable; only a
/// successful current-generation probe suppresses further mount notifications.
struct CardProbeState {
    struct Identity: Equatable {
        let uuid: String
        let path: String
        let mountID: String
    }
    struct Probe: Equatable {
        let id: UUID
        let identity: Identity
    }
    private struct Entry {
        var identity: Identity
        var pending: Probe?
        var delivered = false
    }
    private var entries: [String: Entry] = [:]
    var devices: [String] { Array(entries.keys) }

    mutating func begin(device: String, identity: Identity) -> (probe: Probe?, removed: String?) {
        var removed: String?
        if let old = entries[device], old.identity != identity {
            if old.delivered { removed = old.identity.uuid }
            entries.removeValue(forKey: device)
        }
        var entry = entries[device] ?? Entry(identity: identity)
        guard !entry.delivered, entry.pending == nil else { return (nil, removed) }
        let probe = Probe(id: UUID(), identity: identity)
        entry.pending = probe
        entries[device] = entry
        return (probe, removed)
    }

    mutating func complete(device: String, probe: Probe, ready: Bool) -> Bool {
        guard var entry = entries[device], entry.pending == probe else { return false }
        entry.pending = nil
        entry.delivered = ready
        entries[device] = entry
        return ready
    }

    mutating func remove(device: String) -> String? {
        guard let old = entries.removeValue(forKey: device), old.delivered else { return nil }
        return old.identity.uuid
    }

    mutating func reset() { entries.removeAll() }
}
