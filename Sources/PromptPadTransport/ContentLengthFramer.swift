import Foundation

public enum ContentLengthFramerError: Error, CustomStringConvertible {
  case invalidHeaders
  case missingContentLength
  case invalidContentLength
  case frameTooLarge(Int)

  public var description: String {
    switch self {
    case .invalidHeaders: return "Invalid headers"
    case .missingContentLength: return "Missing Content-Length"
    case .invalidContentLength: return "Invalid Content-Length"
    case let .frameTooLarge(n): return "Frame too large: \(n)"
    }
  }
}

public final class ContentLengthFramer {
  private var buffer = Data()
  private let maxFrameBytes: Int

  public init(maxFrameBytes: Int = 5 * 1024 * 1024) {
    self.maxFrameBytes = maxFrameBytes
  }

  public func append(_ data: Data) throws -> [Data] {
    buffer.append(data)
    var frames: [Data] = []

    while true {
      guard let headerEndRange = buffer.range(of: Data([13, 10, 13, 10])) else {
        break
      }

      let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
      guard let headerText = String(data: headerData, encoding: .utf8) else {
        throw ContentLengthFramerError.invalidHeaders
      }

      let length = try parseContentLength(headerText)
      if length > maxFrameBytes {
        throw ContentLengthFramerError.frameTooLarge(length)
      }

      let bodyStart = headerEndRange.upperBound
      let bodyEnd = bodyStart + length
      if buffer.count < bodyEnd {
        break
      }

      let body = buffer.subdata(in: bodyStart..<bodyEnd)
      frames.append(body)
      buffer.removeSubrange(0..<bodyEnd)
    }

    return frames
  }

  private func parseContentLength(_ headers: String) throws -> Int {
    let lines = headers.components(separatedBy: "\r\n")
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else { continue }
      if String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard let n = Int(value), n >= 0 else {
          throw ContentLengthFramerError.invalidContentLength
        }
        return n
      }
    }
    throw ContentLengthFramerError.missingContentLength
  }
}
