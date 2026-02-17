import Foundation

public enum FileIOError: Error {
  case notAFile
  case fileTooLarge(Int)
}

public enum FileIO {
  public static func readText(at url: URL, maxBytes: Int = 2 * 1024 * 1024) throws -> String {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    if values.isRegularFile != true {
      throw FileIOError.notAFile
    }
    if let size = values.fileSize, size > maxBytes {
      throw FileIOError.fileTooLarge(size)
    }
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
  }

  @discardableResult
  public static func writeTextAtomically(_ text: String, to url: URL) throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let existingPerms: NSNumber? = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
    let tmpName = ".\(url.lastPathComponent).promptpad.tmp.\(UUID().uuidString)"
    let tmpURL = url.deletingLastPathComponent().appendingPathComponent(tmpName)
    let data = Data(text.utf8)
    fm.createFile(atPath: tmpURL.path, contents: data)
    if let perms = existingPerms {
      try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmpURL.path)
    }
    _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
    return Revision.sha256(text: text)
  }
}

