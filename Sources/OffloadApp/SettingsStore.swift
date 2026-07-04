import Foundation
import Observation
import OffloadCore

/// The single owner of AppConfig. Saves are debounced; the engine reads/writes
/// through MainActor hops (see AppState.makeEngine).
@MainActor @Observable
final class SettingsStore {
    var config: AppConfig {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        config = AppConfig.load()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.config.save()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        config.save()
    }
}
