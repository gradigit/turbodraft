import Foundation

public enum JSONRPCID: Codable, Hashable, Sendable {
  case int(Int64)
  case string(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let i = try? container.decode(Int64.self) {
      self = .int(i)
      return
    }
    if let s = try? container.decode(String.self) {
      self = .string(s)
      return
    }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC id")
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .int(i):
      try container.encode(i)
    case let .string(s):
      try container.encode(s)
    }
  }
}

public struct JSONRPCRequest: Codable, Sendable {
  public var jsonrpc: String
  public var id: JSONRPCID?
  public var method: String
  public var params: JSONValue?

  public init(jsonrpc: String = "2.0", id: JSONRPCID?, method: String, params: JSONValue?) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.method = method
    self.params = params
  }
}

public struct JSONRPCErrorObject: Codable, Sendable {
  public var code: Int
  public var message: String
  public var data: JSONValue?

  public init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

public struct JSONRPCResponse: Codable, Sendable {
  public var jsonrpc: String
  public var id: JSONRPCID
  public var result: JSONValue?
  public var error: JSONRPCErrorObject?

  public init(jsonrpc: String = "2.0", id: JSONRPCID, result: JSONValue? = nil, error: JSONRPCErrorObject? = nil) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.result = result
    self.error = error
  }
}

public enum JSONRPCStandardErrorCode {
  public static let parseError = -32700
  public static let invalidRequest = -32600
  public static let methodNotFound = -32601
  public static let invalidParams = -32602
  public static let internalError = -32603
  public static let serverErrorMin = -32099
  public static let serverErrorMax = -32000
}

