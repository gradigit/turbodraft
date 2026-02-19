import Foundation

public enum CommandResolver {
  /// Directories added by common shell-managed version managers that are absent
  /// from the LaunchAgent's minimal PATH.
  private static let supplementalPaths: [String] = {
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

    // Scan all installed node versions newest-first. The first match at resolve time
    // wins, so this prefers the newest version — matching nvm's default behavior.
    // Intentionally broad: nvm aliases contain version strings (e.g. "22"), not
    // directory names, so we must scan all installed versions.
    let nvmVersionsDir = "\(home)/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir) {
      for v in versions.sorted().reversed() {
        extras.append("\(nvmVersionsDir)/\(v)/bin")
      }
    }

    // fnm: check all known base directories (varies by install method / OS)
    let fnmBaseDirs = [
      "\(home)/.local/share/fnm",
      "\(home)/.fnm",
      "\(home)/Library/Application Support/fnm",
    ]
    for base in fnmBaseDirs {
      let fnmDefault = "\(base)/aliases/default"
      if FileManager.default.fileExists(atPath: fnmDefault) {
        extras.append("\(fnmDefault)/bin")
        break
      }
    }

    return extras
  }()

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

  /// Build an environment array suitable for `posix_spawn`, prepending `dir`
  /// to the existing PATH.  Uses `ProcessInfo.processInfo.environment` (a
  /// thread-safe snapshot) instead of the C `environ` pointer.
  public static func buildEnv(prependingToPath dir: String) -> [String] {
    let env = ProcessInfo.processInfo.environment
    var result: [String] = []
    result.reserveCapacity(env.count)
    var pathUpdated = false
    for (key, value) in env {
      if key == "PATH" {
        result.append("PATH=\(dir):\(value)")
        pathUpdated = true
      } else {
        result.append("\(key)=\(value)")
      }
    }
    if !pathUpdated { result.append("PATH=\(dir)") }
    return result
  }
}

