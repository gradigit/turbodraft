import CryptoKit
import Foundation

public enum Revision {
  public static func sha256(text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "sha256:\(hex)"
  }
}

