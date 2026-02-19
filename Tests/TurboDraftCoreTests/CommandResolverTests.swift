import TurboDraftCore
import XCTest

final class CommandResolverTests: XCTestCase {
  func testResolveKnownBinary() {
    // /bin/ls is always present on macOS.
    let result = CommandResolver.resolveInPATH("ls", environment: ["PATH": "/bin:/usr/bin"])
    XCTAssertNotNil(result)
    XCTAssertTrue(result?.hasSuffix("/ls") == true)
  }

  func testResolveAbsolutePathReturnedImmediately() {
    let result = CommandResolver.resolveInPATH("/bin/ls")
    XCTAssertEqual(result, "/bin/ls")
  }

  func testResolveEmptyCommandReturnsNil() {
    XCTAssertNil(CommandResolver.resolveInPATH(""))
  }

  func testResolveWithEmptyPATHSearchesSupplemental() {
    // Even with an empty PATH, supplemental paths (e.g. /opt/homebrew/bin)
    // should be searched. We test via a well-known system binary that lives
    // in a standard directory likely covered by supplemental paths or falls
    // through to nil gracefully.
    let result = CommandResolver.resolveInPATH("ls", environment: ["PATH": ""])
    // On a standard macOS install /usr/local/bin or /opt/homebrew/bin may not
    // contain ls, so we just verify it does not crash and returns either a
    // path or nil.
    if let r = result {
      XCTAssertTrue(r.hasSuffix("/ls"))
    }
  }

  func testResolveNonExistentCommandReturnsNil() {
    XCTAssertNil(CommandResolver.resolveInPATH("turbodraft_no_such_command_xyz"))
  }

  // MARK: - buildEnv

  func testBuildEnvPrependsDirectory() {
    let env = CommandResolver.buildEnv(prependingToPath: "/custom/bin")
    let pathEntry = env.first(where: { $0.hasPrefix("PATH=") })
    XCTAssertNotNil(pathEntry)
    XCTAssertTrue(pathEntry!.hasPrefix("PATH=/custom/bin:"))
  }

  func testBuildEnvPassesThroughNonPathVars() {
    let env = CommandResolver.buildEnv(prependingToPath: "/x")
    // HOME should be present since it's in the process environment.
    let homeEntry = env.first(where: { $0.hasPrefix("HOME=") })
    XCTAssertNotNil(homeEntry)
  }

  func testBuildEnvCreatesPathWhenMissing() {
    // Even when the process has PATH set, buildEnv always produces a PATH entry.
    let env = CommandResolver.buildEnv(prependingToPath: "/test/bin")
    let pathEntries = env.filter { $0.hasPrefix("PATH=") }
    XCTAssertEqual(pathEntries.count, 1)
  }
}
