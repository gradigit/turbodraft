import Foundation

public final class RecoveryStore: @unchecked Sendable {
  private struct StoredSnapshot: Codable, Sendable {
    var id: String
    var createdAt: Date
    var reason: String
    var content: String
    var contentHash: String
  }

  private static let ioLock = NSLock()
  private let maxSnapshotsPerFile: Int
  private let maxBytesPerFile: Int
  private let ttlDays: Int
  private let maxSnapshotBytes: Int

  public init(
    maxSnapshotsPerFile: Int = 256,
    maxBytesPerFile: Int = 1_500_000,
    ttlDays: Int = 14,
    maxSnapshotBytes: Int = 512_000
  ) {
    self.maxSnapshotsPerFile = max(16, maxSnapshotsPerFile)
    self.maxBytesPerFile = max(256_000, maxBytesPerFile)
    self.ttlDays = max(1, ttlDays)
    self.maxSnapshotBytes = max(8_192, maxSnapshotBytes)
  }

  public func loadSnapshots(for fileURL: URL, maxCount: Int = 64) -> [HistorySnapshot] {
    Self.ioLock.lock()
    defer { Self.ioLock.unlock() }

    let path = normalizedPath(for: fileURL)
    let file = snapshotsFileURL(forPath: path)
    var items = readStoredSnapshots(from: file)
    prune(&items)
    writeStoredSnapshots(items, to: file)

    return items.suffix(max(1, maxCount)).map {
      HistorySnapshot(id: $0.id, createdAt: $0.createdAt, reason: $0.reason, content: $0.content)
    }
  }

  @discardableResult
  public func appendSnapshot(_ snapshot: HistorySnapshot, for fileURL: URL) -> String {
    let bytes = snapshot.content.utf8.count
    guard bytes <= maxSnapshotBytes else {
      return snapshot.id
    }

    Self.ioLock.lock()
    defer { Self.ioLock.unlock() }

    let path = normalizedPath(for: fileURL)
    let file = snapshotsFileURL(forPath: path)
    var items = readStoredSnapshots(from: file)
    prune(&items)

    let contentHash = Revision.sha256(text: snapshot.content)
    if let last = items.last, last.contentHash == contentHash {
      return last.id
    }

    items.append(
      StoredSnapshot(
        id: snapshot.id,
        createdAt: snapshot.createdAt,
        reason: snapshot.reason,
        content: snapshot.content,
        contentHash: contentHash
      )
    )

    prune(&items)
    writeStoredSnapshots(items, to: file)
    return snapshot.id
  }

  private func normalizedPath(for fileURL: URL) -> String {
    fileURL.standardizedFileURL.path
  }

  private func prune(_ items: inout [StoredSnapshot]) {
    guard !items.isEmpty else { return }

    let cutoff = Date().addingTimeInterval(TimeInterval(-ttlDays * 24 * 60 * 60))
    items.removeAll { $0.createdAt < cutoff }

    if items.count > maxSnapshotsPerFile {
      items.removeFirst(items.count - maxSnapshotsPerFile)
    }

    var bytes = items.reduce(0) { $0 + $1.content.utf8.count }
    while bytes > maxBytesPerFile, !items.isEmpty {
      bytes -= items[0].content.utf8.count
      items.removeFirst()
    }
  }

  private func snapshotsFileURL(forPath path: String) -> URL {
    let key = Revision.sha256(text: path).replacingOccurrences(of: "sha256:", with: "")
    let dir = recoveryDirURL()
    return dir.appendingPathComponent("\(key).json", isDirectory: false)
  }

  private func recoveryDirURL() -> URL {
    let fm = FileManager.default
    let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base
      .appendingPathComponent("PromptPad", isDirectory: true)
      .appendingPathComponent("recovery", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func readStoredSnapshots(from file: URL) -> [StoredSnapshot] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    return (try? JSONDecoder().decode([StoredSnapshot].self, from: data)) ?? []
  }

  private func writeStoredSnapshots(_ items: [StoredSnapshot], to file: URL) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    try? data.write(to: file, options: [.atomic])
  }
}
