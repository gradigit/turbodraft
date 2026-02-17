import Foundation
import Darwin

public final class DirectoryWatcher: @unchecked Sendable {
  private let url: URL
  private let queue: DispatchQueue
  private var source: DispatchSourceFileSystemObject?
  private var fd: Int32 = -1

  public init(fileURL: URL, queue: DispatchQueue = DispatchQueue(label: "promptpad.filewatch")) throws {
    self.url = fileURL
    self.queue = queue

    fd = open((fileURL as NSURL).fileSystemRepresentation, O_EVTONLY)
    if fd < 0 {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  public init(directoryURL: URL, queue: DispatchQueue = DispatchQueue(label: "promptpad.dirwatch")) throws {
    self.url = directoryURL
    self.queue = queue

    fd = open((directoryURL as NSURL).fileSystemRepresentation, O_EVTONLY)
    if fd < 0 {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  deinit {
    stop()
  }

  public func start(handler: @escaping @Sendable () -> Void) {
    let s = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .rename, .delete, .attrib, .extend],
      queue: queue
    )
    s.setEventHandler(handler: handler)
    s.setCancelHandler { [fd] in
      if fd >= 0 { close(fd) }
    }
    source = s
    s.resume()
  }

  public func stop() {
    source?.cancel()
    source = nil
  }
}
