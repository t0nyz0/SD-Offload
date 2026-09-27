import Foundation

/// Keep blocking reads off the UI actor and forward cancellation to the worker.
/// An in-progress filesystem syscall cannot be interrupted; loops must check
/// Task.isCancelled between calls.
public enum BackgroundWork {
    public static func run<T: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        let worker = Task.detached(priority: priority, operation: operation)
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
