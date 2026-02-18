import Foundation
import TurboDraftProtocol

import Darwin

public enum UnixDomainSocketError: Error, CustomStringConvertible {
  case invalidPath
  case socketFailed(errno: Int32)
  case bindFailed(errno: Int32)
  case listenFailed(errno: Int32)
  case acceptFailed(errno: Int32)
  case connectFailed(errno: Int32)
  case peerRejected
  case alreadyRunning

  public var description: String {
    switch self {
    case .invalidPath: return "Invalid socket path"
    case let .socketFailed(e): return "socket() failed errno=\(e)"
    case let .bindFailed(e): return "bind() failed errno=\(e)"
    case let .listenFailed(e): return "listen() failed errno=\(e)"
    case let .acceptFailed(e): return "accept() failed errno=\(e)"
    case let .connectFailed(e): return "connect() failed errno=\(e)"
    case .peerRejected: return "Peer rejected"
    case .alreadyRunning: return "Socket already in use"
    }
  }
}

public enum UnixDomainSocket {
  public static func connect(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw UnixDomainSocketError.socketFailed(errno: errno) }
    setCloExec(fd)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < maxLen else {
      close(fd)
      throw UnixDomainSocketError.invalidPath
    }

    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      _ = path.withCString { cstr in
        strncpy(ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { $0 }, cstr, maxLen - 1)
      }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let res = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        Darwin.connect(fd, sp, addrLen)
      }
    }
    if res != 0 {
      let e = errno
      close(fd)
      throw UnixDomainSocketError.connectFailed(errno: e)
    }
    return fd
  }

  public static func bindAndListen(path: String, chmodMode: mode_t = 0o600, backlog: Int32 = 16) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw UnixDomainSocketError.socketFailed(errno: errno) }
    setCloExec(fd)

    func doBind(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
      let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
      return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
          Darwin.bind(fd, sp, addrLen)
        }
      }
    }

    // Unlink only if it's a stale socket owned by us (avoid stealing an active instance).
    var st = stat()
    if lstat(path, &st) == 0 {
      if (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() {
        if let existingFD = try? UnixDomainSocket.connect(path: path) {
          close(existingFD)
          close(fd)
          throw UnixDomainSocketError.alreadyRunning
        }
        unlink(path)
      }
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < maxLen else {
      close(fd)
      throw UnixDomainSocketError.invalidPath
    }

    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      _ = path.withCString { cstr in
        strncpy(ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { $0 }, cstr, maxLen - 1)
      }
    }

    var bindRes = doBind(fd, &addr)
    if bindRes != 0 {
      let e = errno
      if e == EADDRINUSE {
        // Possible race: another instance is starting up, or a stale file we couldn't safely remove.
        // Retry connect briefly to distinguish "already running" from stale.
        for _ in 0..<10 {
          if let existingFD = try? UnixDomainSocket.connect(path: path) {
            close(existingFD)
            close(fd)
            throw UnixDomainSocketError.alreadyRunning
          }
          usleep(10_000) // 10ms
        }

        // Still can't connect. If the path is a socket owned by us, treat it as stale and retry bind once.
        var st2 = stat()
        if lstat(path, &st2) == 0, st2.st_uid == getuid() {
          let kind = (st2.st_mode & S_IFMT)
          if kind == S_IFSOCK || kind == S_IFREG {
            _ = unlink(path)
            bindRes = doBind(fd, &addr)
            if bindRes == 0 {
              chmod(path, chmodMode)
              if listen(fd, backlog) != 0 {
                let e2 = errno
                close(fd)
                throw UnixDomainSocketError.listenFailed(errno: e2)
              }
              return fd
            }
          }
        }
      }

      close(fd)
      throw UnixDomainSocketError.bindFailed(errno: e)
    }

    chmod(path, chmodMode)

    if listen(fd, backlog) != 0 {
      let e = errno
      close(fd)
      throw UnixDomainSocketError.listenFailed(errno: e)
    }

    return fd
  }

  public static func accept(listenFD: Int32, requireSameUser: Bool = true) throws -> Int32 {
    let fd = Darwin.accept(listenFD, nil, nil)
    if fd < 0 { throw UnixDomainSocketError.acceptFailed(errno: errno) }
    setCloExec(fd)

    if requireSameUser {
      var euid: uid_t = 0
      var egid: gid_t = 0
      if getpeereid(fd, &euid, &egid) == 0 {
        if euid != getuid() {
          close(fd)
          throw UnixDomainSocketError.peerRejected
        }
      }
    }

    return fd
  }

  private static func setCloExec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFD)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }
  }
}

public final class UnixDomainSocketServer: @unchecked Sendable {
  private let listenFD: Int32
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var _running = true
  private var _stopped = false

  private var running: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _running
  }

  public init(socketPath: String) throws {
    self.listenFD = try UnixDomainSocket.bindAndListen(path: socketPath)
    self.queue = DispatchQueue(label: "turbodraft.uds.accept")
  }

  deinit {
    stop()
  }

  public func start(handler: @escaping @Sendable (Int32) -> Void) {
    queue.async { [listenFD] in
      while self.running {
        do {
          let clientFD = try UnixDomainSocket.accept(listenFD: listenFD, requireSameUser: true)
          handler(clientFD)
        } catch {
          if self.running {
            continue
          }
          return
        }
      }
    }
  }

  public func stop() {
    lock.lock()
    let wasRunning = _running
    _running = false
    let alreadyStopped = _stopped
    _stopped = true
    lock.unlock()
    if wasRunning && !alreadyStopped {
      close(listenFD)
    }
  }
}
