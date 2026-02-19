import Foundation

public enum CommandResolver {
  /// Directories added by common shell-managed version managers that are absent
  /// from the LaunchAgent's minimal PATH.
  private static var supplementalPaths: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var extras: [String] = [
      // homebrew (Apple Silicon)
      "/opt/homebrew/bin",
      // homebrew (Intel)
      "/usr/local/bin",
      // pnpm
      "\(home)/Library/pnpm",
      // cargo (Rust)
      "\(home)/.cargo/bin",
    ]

    // nvm: pick up whichever node version is active by scanning aliases/default symlink
    let nvmDefault = "\(home)/.nvm/alias/default"
    if let version = try? String(contentsOfFile: nvmDefault, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !version.isEmpty {
      extras.append("\(home)/.nvm/versions/node/\(version)/bin")
    }
    // Also scan all installed nvm node versions as fallback (first found wins)
    let nvmVersionsDir = "\(home)/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir) {
      for v in versions.sorted().reversed() {
        extras.append("\(nvmVersionsDir)/\(v)/bin")
      }
    }

    // fnm
    let fnmDefault = "\(home)/.fnm/aliases/default"
    if FileManager.default.fileExists(atPath: fnmDefault) {
      extras.append("\(fnmDefault)/bin")
    }

    return extras
  }

  public static func resolveInPATH(_ command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard !command.isEmpty else { return nil }
    if command.contains("/") { return command }

    let envPath = environment["PATH"] ?? ""
    let envDirs = envPath.isEmpty ? [] : envPath.split(separator: ":").map(String.init)
    // Supplement with shell-managed paths that LaunchAgent environments omit.
    // Use a set to deduplicate while preserving priority order (env PATH first).
    var seen = Set(envDirs)
    var dirs = envDirs
    for extra in supplementalPaths where !seen.contains(extra) {
      seen.insert(extra)
      dirs.append(extra)
    }

    let fm = FileManager.default
    for dir in dirs {
      let candidate = dir + "/" + command
      if fm.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}

