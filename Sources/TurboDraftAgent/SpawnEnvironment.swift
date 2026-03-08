import Foundation

public enum SpawnEnvironment {
  /// Merges KEY=VALUE entries with deterministic override behavior.
  ///
  /// - Existing keys in `base` are replaced by `overrides`.
  /// - New override keys are appended (sorted by key for stability).
  public static func merged(base: [String], overrides: [String: String]) -> [String] {
    guard !overrides.isEmpty else { return base }

    var out: [String] = []
    out.reserveCapacity(base.count + overrides.count)
    var seen = Set<String>()

    for entry in base {
      guard let eq = entry.firstIndex(of: "=") else {
        out.append(entry)
        continue
      }
      let key = String(entry[..<eq])
      if key.isEmpty {
        out.append(entry)
        continue
      }
      if let value = overrides[key] {
        out.append("\(key)=\(value)")
        seen.insert(key)
      } else {
        out.append(entry)
      }
    }

    for key in overrides.keys.sorted() where !seen.contains(key) {
      guard let value = overrides[key] else { continue }
      out.append("\(key)=\(value)")
    }

    return out
  }
}
