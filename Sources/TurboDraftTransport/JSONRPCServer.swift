import Foundation
import TurboDraftProtocol

public typealias JSONRPCHandler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse?

public final class JSONRPCServerConnection: @unchecked Sendable {
  private let connection: JSONRPCConnection
  private let handler: JSONRPCHandler

  public init(connection: JSONRPCConnection, handler: @escaping JSONRPCHandler) {
    self.connection = connection
    self.handler = handler
  }

  @discardableResult
  public func run() -> Task<Void, Never> {
    Task(priority: .userInitiated) { [connection, handler] in
      while true {
        do {
          let req = try connection.readRequest()
          if let resp = await handler(req) {
            try? connection.sendJSON(resp)
          }
        } catch {
          return
        }
      }
    }
  }
}
