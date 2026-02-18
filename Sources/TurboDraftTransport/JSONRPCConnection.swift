import Foundation
import TurboDraftProtocol
import Darwin

public enum JSONRPCConnectionError: Error, CustomStringConvertible {
  case eof
  case invalidMessage
  case readFailed(errno: Int32)
  case writeFailed(errno: Int32)

  public var description: String {
    switch self {
    case .eof: return "EOF"
    case .invalidMessage: return "Invalid message"
    case let .readFailed(e): return "read() failed errno=\(e)"
    case let .writeFailed(e): return "write() failed errno=\(e)"
    }
  }
}

public final class JSONRPCConnection: @unchecked Sendable {
  private let readHandle: FileHandle
  private let writeHandle: FileHandle
  private let readFD: Int32
  private let writeFD: Int32
  private let framer: ContentLengthFramer
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder
  private let writeLock = NSLock()
  private var pendingFrames: [Data] = []

  public init(readHandle: FileHandle, writeHandle: FileHandle, maxFrameBytes: Int = 5 * 1024 * 1024) {
    self.readHandle = readHandle
    self.writeHandle = writeHandle
    self.readFD = readHandle.fileDescriptor
    self.writeFD = writeHandle.fileDescriptor
    self.framer = ContentLengthFramer(maxFrameBytes: maxFrameBytes)
    self.decoder = JSONDecoder()
    self.encoder = JSONEncoder()
  }

  public func sendJSON<T: Encodable>(_ message: T) throws {
    let body = try encoder.encode(message)
    try sendFrame(body)
  }

  public func sendFrame(_ body: Data) throws {
    writeLock.lock()
    defer { writeLock.unlock() }
    let header = "Content-Length: \(body.count)\r\n\r\n"
    var data = Data(header.utf8)
    data.append(body)
    try data.withUnsafeBytes { rawBuf in
      guard let base = rawBuf.baseAddress else { return }
      var sent = 0
      while sent < rawBuf.count {
        let n = Darwin.write(writeFD, base.advanced(by: sent), rawBuf.count - sent)
        if n < 0 {
          if errno == EINTR { continue }
          throw JSONRPCConnectionError.writeFailed(errno: errno)
        }
        if n == 0 {
          throw JSONRPCConnectionError.writeFailed(errno: 0)
        }
        sent += n
      }
    }
  }

  public func readRequest() throws -> JSONRPCRequest {
    let frame = try nextFrame()
    return try decoder.decode(JSONRPCRequest.self, from: frame)
  }

  public func readResponse() throws -> JSONRPCResponse {
    let frame = try nextFrame()
    return try decoder.decode(JSONRPCResponse.self, from: frame)
  }

  private func nextFrame() throws -> Data {
    if !pendingFrames.isEmpty {
      return pendingFrames.removeFirst()
    }

    while pendingFrames.isEmpty {
      let frames = try framer.append(try readChunk())
      if !frames.isEmpty {
        pendingFrames.append(contentsOf: frames)
      }
    }
    return pendingFrames.removeFirst()
  }

  private func readChunk() throws -> Data {
    var buf = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let n = Darwin.read(readFD, &buf, buf.count)
      if n < 0 {
        if errno == EINTR { continue }
        throw JSONRPCConnectionError.readFailed(errno: errno)
      }
      if n == 0 {
        throw JSONRPCConnectionError.eof
      }
      return Data(buf[0..<n])
    }
  }
}
