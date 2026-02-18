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

  public func run() {
    Task.detached(priority: .utility) { [connection, handler] in
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
