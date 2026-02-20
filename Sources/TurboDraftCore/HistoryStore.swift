import Foundation

public struct HistorySnapshot: Sendable, Equatable {
  public var id: String
  public var createdAt: Date
  public var reason: String
  public var content: String

  public init(id: String = UUID().uuidString, createdAt: Date = Date(), reason: String, content: String) {
    self.id = id
    self.createdAt = createdAt
    self.reason = reason
    self.content = content
  }
}

public struct HistoryStore: Sendable {
  private var maxCount: Int
  private var maxBytes: Int
  private var items: [HistorySnapshot] = []
  private var itemSizes: [Int] = []
  private var totalBytes: Int = 0

  public init(maxCount: Int = 32, maxBytes: Int = 2_000_000) {
    self.maxCount = maxCount
    self.maxBytes = maxBytes
  }

  public mutating func append(_ snapshot: HistorySnapshot) {
    // Consecutive duplicate snapshots are pure memory churn and provide no
    // additional restore value.
    if let last = items.last, last.content == snapshot.content {
      return
    }

    let size = snapshot.content.utf8.count
    items.append(snapshot)
    itemSizes.append(size)
    totalBytes += size
    trimToBudget()
  }

  public func all() -> [HistorySnapshot] { items }

  public func find(id: String) -> HistorySnapshot? {
    items.last { $0.id == id }
  }

  private mutating func trimToBudget() {
    while items.count > maxCount, !items.isEmpty {
      totalBytes -= itemSizes.removeFirst()
      items.removeFirst()
    }

    // Keep at least one snapshot, even when a single entry exceeds budget.
    while totalBytes > maxBytes, items.count > 1 {
      totalBytes -= itemSizes.removeFirst()
      items.removeFirst()
    }
  }
}
