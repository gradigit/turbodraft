import Foundation

public struct SessionInfo: Sendable, Equatable {
  public var sessionId: String
  public var fileURL: URL
  public var content: String
  public var diskRevision: String
  public var isDirty: Bool
  public var conflictSnapshotId: String?
  public var bannerMessage: String?

  public init(
    sessionId: String,
    fileURL: URL,
    content: String,
    diskRevision: String,
    isDirty: Bool,
    conflictSnapshotId: String? = nil,
    bannerMessage: String? = nil
  ) {
    self.sessionId = sessionId
    self.fileURL = fileURL
    self.content = content
    self.diskRevision = diskRevision
    self.isDirty = isDirty
    self.conflictSnapshotId = conflictSnapshotId
    self.bannerMessage = bannerMessage
  }
}

public actor EditorSession {
  private struct RevisionWaiter {
    let baseRevision: String
    let continuation: CheckedContinuation<SessionInfo?, Never>
    let timeoutTask: Task<Void, Never>?
  }

  private var sessionId: String = UUID().uuidString
  private var fileURL: URL?
  private var content: String = ""
  private var diskRevision: String = Revision.sha256(text: "")
  private var isDirty: Bool = false
  private var history = HistoryStore(maxCount: 64)
  private let recoveryStore = RecoveryStore()
  private var conflictSnapshotId: String?
  private var bannerMessage: String?

  private var isClosed: Bool = true
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var revisionWaiters: [UUID: RevisionWaiter] = [:]

  public init() {}

  public func open(fileURL: URL) throws -> SessionInfo {
    // Opening a new file/session supersedes any existing waiters from
    // previous external-editor invocations. Release them to avoid stuck CLIs.
    if !waiters.isEmpty {
      let ws = waiters
      waiters.removeAll()
      for w in ws { w.resume() }
    }
    clearRevisionWaiters(with: nil)

    self.fileURL = fileURL
    self.sessionId = UUID().uuidString
    self.isClosed = false

    if !FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }

    let text = try FileIO.readText(at: fileURL)
    let recovered = recoveryStore.loadSnapshots(for: fileURL, maxCount: 48)

    self.history = HistoryStore(maxCount: 64)
    for snap in recovered.suffix(48) {
      self.history.append(snap)
    }

    self.content = text
    self.diskRevision = Revision.sha256(text: text)
    self.isDirty = false
    if let recoverable = recovered.last(where: { $0.content != text }) {
      self.conflictSnapshotId = recoverable.id
      self.bannerMessage = "Recovery available from previous session. You can restore your previous draft."
    } else {
      self.conflictSnapshotId = nil
      self.bannerMessage = nil
    }

    let openSnap = HistorySnapshot(reason: "open_buffer", content: text)
    self.history.append(openSnap)
    _ = recoveryStore.appendSnapshot(openSnap, for: fileURL)

    return SessionInfo(
      sessionId: sessionId,
      fileURL: fileURL,
      content: content,
      diskRevision: diskRevision,
      isDirty: isDirty,
      conflictSnapshotId: conflictSnapshotId,
      bannerMessage: bannerMessage
    )
  }

  public func updateBufferContent(_ newContent: String) {
    self.content = newContent
    self.isDirty = true
  }

  public func snapshot(reason: String) -> String? {
    guard let url = fileURL else { return nil }
    let snap = HistorySnapshot(reason: reason, content: content)
    history.append(snap)
    _ = recoveryStore.appendSnapshot(snap, for: url)
    return snap.id
  }

  public func currentInfo() -> SessionInfo? {
    guard let url = fileURL else { return nil }
    return SessionInfo(
      sessionId: sessionId,
      fileURL: url,
      content: content,
      diskRevision: diskRevision,
      isDirty: isDirty,
      conflictSnapshotId: conflictSnapshotId,
      bannerMessage: bannerMessage
    )
  }

  public func autosave(reason: String = "autosave") throws -> SessionInfo? {
    guard let url = fileURL else { return nil }
    guard isDirty else { return currentInfo() }

    let snap = HistorySnapshot(reason: reason, content: content)
    history.append(snap)
    _ = recoveryStore.appendSnapshot(snap, for: url)
    let newRev = try FileIO.writeTextAtomically(content, to: url)
    diskRevision = newRev
    isDirty = false
    bannerMessage = nil
    conflictSnapshotId = nil
    notifyRevisionWaitersForCurrentRevision()
    return currentInfo()
  }

  public func applyExternalDiskChange() throws -> SessionInfo? {
    guard let url = fileURL else { return nil }
    let diskText = try FileIO.readText(at: url)
    let diskRev = Revision.sha256(text: diskText)
    if diskRev == diskRevision {
      return nil
    }

    if isDirty {
      let snap = HistorySnapshot(reason: "before_external_apply", content: content)
      history.append(snap)
      _ = recoveryStore.appendSnapshot(snap, for: url)
      conflictSnapshotId = snap.id
      bannerMessage = "File changed externally. Newest version applied. You can restore your previous buffer."
    } else {
      conflictSnapshotId = nil
      bannerMessage = nil
    }

    content = diskText
    diskRevision = diskRev
    isDirty = false
    notifyRevisionWaitersForCurrentRevision()
    return currentInfo()
  }

  public func restoreSnapshot(id: String) -> SessionInfo? {
    guard let url = fileURL else { return nil }
    guard let snap = history.find(id: id) else { return currentInfo() }
    content = snap.content
    isDirty = true
    conflictSnapshotId = nil
    bannerMessage = "Restored previous buffer. Pending autosave."
    return SessionInfo(
      sessionId: sessionId,
      fileURL: url,
      content: content,
      diskRevision: diskRevision,
      isDirty: isDirty,
      conflictSnapshotId: conflictSnapshotId,
      bannerMessage: bannerMessage
    )
  }

  public func markClosed() {
    isClosed = true
    let ws = waiters
    waiters.removeAll()
    for w in ws { w.resume() }
    clearRevisionWaiters(with: nil)
  }

  public func waitUntilRevisionChange(baseRevision: String, timeoutMs: Int?) async -> SessionInfo? {
    guard fileURL != nil else { return nil }
    if diskRevision != baseRevision {
      return currentInfo()
    }

    let waiterID = UUID()
    return await withCheckedContinuation { (cont: CheckedContinuation<SessionInfo?, Never>) in
      let timeoutTask: Task<Void, Never>?
      if let timeoutMs {
        let pollIntervalNs: UInt64 = 20_000_000
        let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
        timeoutTask = Task { [weak self] in
          var elapsedNs: UInt64 = 0
          while elapsedNs < timeoutNs {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            elapsedNs += pollIntervalNs
            if Task.isCancelled { return }
            _ = try? await self?.applyExternalDiskChange()
          }
          await self?.finishRevisionWaiter(id: waiterID, with: nil)
        }
      } else {
        timeoutTask = nil
      }

      revisionWaiters[waiterID] = RevisionWaiter(
        baseRevision: baseRevision,
        continuation: cont,
        timeoutTask: timeoutTask
      )
      notifyRevisionWaitersForCurrentRevision()
    }
  }

  public func waitUntilClosed(timeoutMs: Int?) async -> Bool {
    if isClosed { return true }

    if let timeoutMs {
      return await withTaskGroup(of: Bool.self) { group in
        group.addTask { [weak self] in
          guard let self else { return false }
          await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await self.addWaiter(cont) }
          }
          return true
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
      }
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      addWaiter(cont)
    }
    return true
  }

  private func addWaiter(_ cont: CheckedContinuation<Void, Never>) {
    if isClosed {
      cont.resume()
      return
    }
    waiters.append(cont)
  }

  private func notifyRevisionWaitersForCurrentRevision() {
    guard !revisionWaiters.isEmpty else { return }
    guard let info = currentInfo() else {
      clearRevisionWaiters(with: nil)
      return
    }

    let ready = revisionWaiters.compactMap { id, waiter in
      waiter.baseRevision != info.diskRevision ? id : nil
    }
    for id in ready {
      finishRevisionWaiter(id: id, with: info)
    }
  }

  private func finishRevisionWaiter(id: UUID, with info: SessionInfo?) {
    guard let waiter = revisionWaiters.removeValue(forKey: id) else { return }
    waiter.timeoutTask?.cancel()
    waiter.continuation.resume(returning: info)
  }

  private func clearRevisionWaiters(with info: SessionInfo?) {
    let ids = Array(revisionWaiters.keys)
    for id in ids {
      finishRevisionWaiter(id: id, with: info)
    }
  }
}
