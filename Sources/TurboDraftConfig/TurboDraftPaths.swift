import Foundation

public enum TurboDraftPaths {
  public static func applicationSupportDir() throws -> URL {
    let fm = FileManager.default
    let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("TurboDraft", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  public static func defaultSocketPath() -> String {
    let dir = (try? applicationSupportDir()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return dir.appendingPathComponent("turbodraft.sock").path
  }

  public static func defaultConfigPath() -> String {
    let dir = (try? applicationSupportDir()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return dir.appendingPathComponent("config.json").path
  }

  public static func themesDir() -> URL {
    let dir = ((try? applicationSupportDir()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
      .appendingPathComponent("themes", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

