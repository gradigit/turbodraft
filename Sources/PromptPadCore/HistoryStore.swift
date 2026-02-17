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
  private var items: [HistorySnapshot] = []

  public init(maxCount: Int = 32) {
    self.maxCount = maxCount
  }

  public mutating func append(_ snapshot: HistorySnapshot) {
    items.append(snapshot)
    if items.count > maxCount {
      items.removeFirst(items.count - maxCount)
    }
  }

  public func all() -> [HistorySnapshot] { items }

  public func find(id: String) -> HistorySnapshot? {
    items.last { $0.id == id }
  }
}

