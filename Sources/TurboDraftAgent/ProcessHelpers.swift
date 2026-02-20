import Foundation

/// Shared POSIX helpers for spawning child processes.
/// Used by all agent adapters for pipe/fd setup.

enum ProcessHelperError: Error {
  case writeFailed(errno: Int32)
}

func setCloExec(_ fd: Int32) {
  let flags = fcntl(fd, F_GETFD)
  if flags >= 0 {
    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
  }
}

func setNonBlocking(_ fd: Int32) {
  let flags = fcntl(fd, F_GETFL)
  if flags >= 0 {
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  }
}

func writeAll(fd: Int32, data: Data) throws {
  try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    guard let base = raw.baseAddress else { return }
    var offset = 0
    while offset < raw.count {
      let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
      if n > 0 {
        offset += n
        continue
      }
      if n == -1, errno == EINTR {
        continue
      }
      throw ProcessHelperError.writeFailed(errno: errno)
    }
  }
}
