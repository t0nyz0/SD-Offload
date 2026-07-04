import Foundation
import OffloadCore

/// The real engine. M0: skeleton that owns the event stream and config access.
/// M1 wires CardWatcher; M2–M4 wire the session pipeline and wipe path.
public final class EngineController: EngineControlling, @unchecked Sendable {
    public typealias ConfigProvider = @Sendable () async -> AppConfig
    public typealias ConfigMutator = @Sendable (_ mutate: @Sendable @escaping (inout AppConfig) -> Void) async -> Void

    private let configProvider: ConfigProvider
    private let configMutator: ConfigMutator
    private let journal: Journal

    private var continuation: AsyncStream<EngineEvent>.Continuation!
    public let events: AsyncStream<EngineEvent>

    public init(configProvider: @escaping ConfigProvider,
                configMutator: @escaping ConfigMutator,
                journal: Journal) {
        self.configProvider = configProvider
        self.configMutator = configMutator
        self.journal = journal
        var cont: AsyncStream<EngineEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func emit(_ event: EngineEvent) {
        continuation.yield(event)
    }

    // MARK: - EngineControlling (M1+ fills these in)

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            let config = await self.configProvider()
            self.emit(.nasGlance(EngineGlance.quickNASGlance(config: config)))
        }
    }

    public func consentToIngest(cardUUID: String, remember: CardPolicy?) {}
    public func declineIngest(cardUUID: String, remember: CardPolicy?) {}
    public func pause() {}
    public func resume() {}
    public func cancel() {}
    public func confirmWipe() {}
    public func cancelWipe() {}
    public func eject() {}
    public func retry() {}

    public func refreshNASGlance() {
        Task { [weak self] in
            guard let self else { return }
            let config = await self.configProvider()
            self.emit(.nasGlance(EngineGlance.quickNASGlance(config: config)))
        }
    }
}
