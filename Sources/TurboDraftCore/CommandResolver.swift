import Foundation

public enum CommandResolver {
  public static func resolveInPATH(_ command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard !command.isEmpty else { return nil }
    if command.contains("/") { return command }

    guard let path = environment["PATH"], !path.isEmpty else { return nil }
    let fm = FileManager.default
    for dir in path.split(separator: ":") {
      let candidate = String(dir) + "/" + command
      if fm.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}

