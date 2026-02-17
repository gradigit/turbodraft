import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let b = try? container.decode(Bool.self) {
      self = .bool(b)
      return
    }
    if let i = try? container.decode(Int64.self) {
      self = .int(i)
      return
    }
    if let d = try? container.decode(Double.self) {
      self = .double(d)
      return
    }
    if let s = try? container.decode(String.self) {
      self = .string(s)
      return
    }
    if let a = try? container.decode([JSONValue].self) {
      self = .array(a)
      return
    }
    if let o = try? container.decode([String: JSONValue].self) {
      self = .object(o)
      return
    }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(b):
      try container.encode(b)
    case let .int(i):
      try container.encode(i)
    case let .double(d):
      try container.encode(d)
    case let .string(s):
      try container.encode(s)
    case let .array(a):
      try container.encode(a)
    case let .object(o):
      try container.encode(o)
    }
  }

  public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    let data = try JSONEncoder().encode(self)
    return try decoder.decode(T.self, from: data)
  }
}

