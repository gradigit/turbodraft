import Foundation

public enum PromptPadPaths {
  public static func applicationSupportDir() throws -> URL {
    let fm = FileManager.default
    let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("PromptPad", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  public static func defaultSocketPath() -> String {
    let dir = (try? applicationSupportDir()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return dir.appendingPathComponent("promptpad.sock").path
  }

  public static func defaultConfigPath() -> String {
    let dir = (try? applicationSupportDir()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return dir.appendingPathComponent("config.json").path
  }
}

