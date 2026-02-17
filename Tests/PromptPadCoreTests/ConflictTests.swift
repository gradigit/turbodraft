import PromptPadCore
import XCTest

final class ConflictTests: XCTestCase {
  func testExternalChangeOverwritesDirtyAndCreatesSnapshot() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("p.md")
    try "a".data(using: .utf8)!.write(to: file)

    let session = EditorSession()
    _ = try await session.open(fileURL: file)
    await session.updateBufferContent("local-edit")
    try "disk-edit".data(using: .utf8)!.write(to: file, options: [.atomic])

    let info = try await session.applyExternalDiskChange()
    XCTAssertNotNil(info?.bannerMessage)
    XCTAssertNotNil(info?.conflictSnapshotId)
    XCTAssertEqual(info?.content, "disk-edit")
  }
}

