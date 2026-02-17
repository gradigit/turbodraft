import Foundation

public final class AsyncDebouncer: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  public init() {}

  public func schedule(delayMs: Int, operation: @escaping @Sendable () async -> Void) {
    lock.lock()
    task?.cancel()
    let t = Task {
      try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
      if Task.isCancelled { return }
      await operation()
    }
    task = t
    lock.unlock()
  }

  public func cancel() {
    lock.lock()
    task?.cancel()
    task = nil
    lock.unlock()
  }
}

