import Foundation

public struct PromptPadCapabilities: Codable, Sendable, Equatable {
  public var supportsWait: Bool
  public var supportsAgentDraft: Bool
  public var supportsQuit: Bool

  public init(supportsWait: Bool, supportsAgentDraft: Bool, supportsQuit: Bool) {
    self.supportsWait = supportsWait
    self.supportsAgentDraft = supportsAgentDraft
    self.supportsQuit = supportsQuit
  }
}

public struct HelloParams: Codable, Sendable, Equatable {
  public var client: String
  public var clientVersion: String?

  public init(client: String, clientVersion: String? = nil) {
    self.client = client
    self.clientVersion = clientVersion
  }
}

public struct HelloResult: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var capabilities: PromptPadCapabilities
  public var serverPid: Int

  public init(protocolVersion: Int, capabilities: PromptPadCapabilities, serverPid: Int) {
    self.protocolVersion = protocolVersion
    self.capabilities = capabilities
    self.serverPid = serverPid
  }
}

public struct SessionOpenParams: Codable, Sendable, Equatable {
  public var path: String
  public var line: Int?
  public var column: Int?
  public var requestId: String?

  public init(path: String, line: Int? = nil, column: Int? = nil, requestId: String? = nil) {
    self.path = path
    self.line = line
    self.column = column
    self.requestId = requestId
  }
}

public struct SessionOpenResult: Codable, Sendable, Equatable {
  public var sessionId: String
  public var path: String
  public var content: String
  public var revision: String
  public var isDirty: Bool

  public init(sessionId: String, path: String, content: String, revision: String, isDirty: Bool) {
    self.sessionId = sessionId
    self.path = path
    self.content = content
    self.revision = revision
    self.isDirty = isDirty
  }
}

public struct SessionReloadParams: Codable, Sendable, Equatable {
  public var sessionId: String
  public init(sessionId: String) { self.sessionId = sessionId }
}

public struct SessionReloadResult: Codable, Sendable, Equatable {
  public var content: String
  public var revision: String
  public init(content: String, revision: String) {
    self.content = content
    self.revision = revision
  }
}

public struct SessionWaitForRevisionParams: Codable, Sendable, Equatable {
  public var sessionId: String
  public var baseRevision: String
  public var timeoutMs: Int?

  public init(sessionId: String, baseRevision: String, timeoutMs: Int? = nil) {
    self.sessionId = sessionId
    self.baseRevision = baseRevision
    self.timeoutMs = timeoutMs
  }
}

public struct SessionWaitForRevisionResult: Codable, Sendable, Equatable {
  public var content: String
  public var revision: String
  public var changed: Bool

  public init(content: String, revision: String, changed: Bool) {
    self.content = content
    self.revision = revision
    self.changed = changed
  }
}

public struct SessionSaveParams: Codable, Sendable, Equatable {
  public var sessionId: String
  public var baseRevision: String?
  public var content: String
  public var force: Bool?

  public init(sessionId: String, baseRevision: String? = nil, content: String, force: Bool? = nil) {
    self.sessionId = sessionId
    self.baseRevision = baseRevision
    self.content = content
    self.force = force
  }
}

public struct SessionSaveResult: Codable, Sendable, Equatable {
  public var ok: Bool
  public var revision: String
  public init(ok: Bool, revision: String) {
    self.ok = ok
    self.revision = revision
  }
}

public struct SessionWaitParams: Codable, Sendable, Equatable {
  public var sessionId: String
  public var timeoutMs: Int?

  public init(sessionId: String, timeoutMs: Int? = nil) {
    self.sessionId = sessionId
    self.timeoutMs = timeoutMs
  }
}

public struct SessionWaitResult: Codable, Sendable, Equatable {
  public var reason: String
  public init(reason: String) { self.reason = reason }
}
