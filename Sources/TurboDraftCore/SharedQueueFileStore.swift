import Darwin
import Foundation
import TurboDraftProtocol

public enum SharedQueueLineEncoding: String, Sendable, Equatable {
  case jsonObject
  case plainText
}

public enum SharedQueueFileStoreError: Error, Equatable {
  case conflict(expected: String?, actual: String?)
  case lockUnavailable(errno: Int32)
}

public struct SharedQueueItem: Sendable, Equatable {
  public var localID: String
  public var persistedID: String?
  public var prompt: String
  public var addedUs: Int64?
  public var encoding: SharedQueueLineEncoding
  public var jsonFields: [String: JSONValue]?

  public init(
    localID: String,
    persistedID: String?,
    prompt: String,
    addedUs: Int64?,
    encoding: SharedQueueLineEncoding,
    jsonFields: [String: JSONValue]? = nil
  ) {
    self.localID = localID
    self.persistedID = persistedID
    self.prompt = prompt
    self.addedUs = addedUs
    self.encoding = encoding
    self.jsonFields = jsonFields
  }

  public static func newItem(
    prompt: String = "",
    id: String = UUID().uuidString,
    addedUs: Int64 = SharedQueueFileStore.nowMicros()
  ) -> SharedQueueItem {
    let fields: [String: JSONValue] = [
      "id": .string(id),
      "prompt": .string(prompt),
      "added_us": .int(addedUs),
    ]
    return SharedQueueItem(
      localID: "id:\(id)",
      persistedID: id,
      prompt: prompt,
      addedUs: addedUs,
      encoding: .jsonObject,
      jsonFields: fields
    )
  }
}

public struct SharedQueueFileSnapshot: Sendable, Equatable {
  public var items: [SharedQueueItem]
  public var fileExists: Bool
  public var fingerprint: String?

  public init(items: [SharedQueueItem], fileExists: Bool, fingerprint: String?) {
    self.items = items
    self.fileExists = fileExists
    self.fingerprint = fingerprint
  }
}

public enum SharedQueueFileStore {
  public static func load(from url: URL) throws -> SharedQueueFileSnapshot {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
      return SharedQueueFileSnapshot(items: [], fileExists: false, fingerprint: nil)
    }

    let text = try FileIO.readText(at: url, maxBytes: 4 * 1024 * 1024)
    let items = parse(text: text)
    return SharedQueueFileSnapshot(
      items: items,
      fileExists: true,
      fingerprint: Revision.sha256(text: text)
    )
  }

  @discardableResult
  public static func write(
    _ items: [SharedQueueItem],
    to url: URL,
    expectedFingerprint: String? = nil,
    enforceFingerprint: Bool = false
  ) throws -> SharedQueueFileSnapshot {
    try withAdvisoryLock(for: url) {
      let fm = FileManager.default
      let currentSnapshot = try load(from: url)
      if enforceFingerprint, currentSnapshot.fingerprint != expectedFingerprint {
        throw SharedQueueFileStoreError.conflict(
          expected: expectedFingerprint,
          actual: currentSnapshot.fingerprint
        )
      }

      if items.isEmpty {
        if fm.fileExists(atPath: url.path) {
          try fm.removeItem(at: url)
        }
        return SharedQueueFileSnapshot(items: [], fileExists: false, fingerprint: nil)
      }

      let text = try serialize(items: items)
      _ = try FileIO.writeTextAtomically(text, to: url)
      return SharedQueueFileSnapshot(
        items: items,
        fileExists: true,
        fingerprint: Revision.sha256(text: text)
      )
    }
  }

  public static func nowMicros(date: Date = Date()) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000.0).rounded())
  }

  public static func parse(text: String) -> [SharedQueueItem] {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    var items: [SharedQueueItem] = []
    items.reserveCapacity(lines.count)

    for (index, rawLine) in lines.enumerated() {
      if let item = parseLine(rawLine, index: index) {
        items.append(item)
      }
    }
    return items
  }

  public static func serialize(items: [SharedQueueItem]) throws -> String {
    let lines = try items.map(serializeLine)
    return lines.joined(separator: "\n") + "\n"
  }

  private static func parseLine(_ rawLine: String, index: Int) -> SharedQueueItem? {
    guard !rawLine.isEmpty else { return nil }
    if rawLine.first == "{",
       let data = rawLine.data(using: .utf8),
       let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
       case let .string(prompt)? = object["prompt"] {
      let persistedID: String?
      if case let .string(id)? = object["id"] {
        persistedID = id
      } else {
        persistedID = nil
      }

      let addedUs: Int64?
      switch object["added_us"] {
      case let .int(value)?:
        addedUs = value
      case let .double(value)?:
        addedUs = Int64(value.rounded())
      default:
        addedUs = nil
      }

      return SharedQueueItem(
        localID: persistedID.map { "id:\($0)" } ?? "json:\(Revision.sha256(text: "\(index)|\(rawLine)"))",
        persistedID: persistedID,
        prompt: prompt,
        addedUs: addedUs,
        encoding: .jsonObject,
        jsonFields: object
      )
    }

    return SharedQueueItem(
      localID: "plain:\(Revision.sha256(text: "\(index)|\(rawLine)"))",
      persistedID: nil,
      prompt: rawLine,
      addedUs: nil,
      encoding: .plainText,
      jsonFields: nil
    )
  }

  private static func serializeLine(_ item: SharedQueueItem) throws -> String {
    if item.encoding == .plainText,
       item.jsonFields == nil,
       item.persistedID == nil,
       item.addedUs == nil,
       !item.prompt.contains(where: \.isNewline) {
      return item.prompt
    }

    var fields = item.jsonFields ?? [:]
    if let id = item.persistedID {
      fields["id"] = .string(id)
    }
    if let addedUs = item.addedUs {
      fields["added_us"] = .int(addedUs)
    }
    fields["prompt"] = .string(item.prompt)

    let data = try JSONEncoder().encode(fields)
    return String(decoding: data, as: UTF8.self)
  }

  private static func withAdvisoryLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw SharedQueueFileStoreError.lockUnavailable(errno: errno)
    }
    defer {
      _ = flock(fd, LOCK_UN)
      _ = close(fd)
    }
    guard flock(fd, LOCK_EX) == 0 else {
      throw SharedQueueFileStoreError.lockUnavailable(errno: errno)
    }
    return try body()
  }
}
