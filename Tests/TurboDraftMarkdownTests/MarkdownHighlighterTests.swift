import TurboDraftMarkdown
import XCTest

final class MarkdownHighlighterTests: XCTestCase {
  func testHeaderHighlight() {
    let text = "# Hello\nWorld"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertEqual(hs.count, 2)
    XCTAssertEqual(hs[0].kind, .headerMarker(level: 1))
    XCTAssertEqual((text as NSString).substring(with: hs[0].range), "#")
    XCTAssertEqual(hs[1].kind, .headerText(level: 1))
    XCTAssertEqual((text as NSString).substring(with: hs[1].range), "Hello")
  }

  func testCodeFenceAndBlockLineHighlight() {
    let text = "```swift\ncode\n```"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertEqual(hs.count, 4)
    XCTAssertEqual(hs[0].kind, .codeFenceDelimiter)
    XCTAssertEqual((text as NSString).substring(with: hs[0].range), "```")
    XCTAssertEqual(hs[1].kind, .codeFenceInfo)
    XCTAssertEqual((text as NSString).substring(with: hs[1].range), "swift")
    XCTAssertEqual(hs[2].kind, .codeBlockLine)
    XCTAssertEqual((text as NSString).substring(with: hs[2].range), "code")
    XCTAssertEqual(hs[3].kind, .codeFenceDelimiter)
    XCTAssertEqual((text as NSString).substring(with: hs[3].range), "```")
  }

  func testInlineCodeHighlight() {
    let text = "Use `code` here"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertEqual(hs.count, 3)
    XCTAssertEqual(hs[0].kind, .inlineCodeDelimiter)
    XCTAssertEqual((text as NSString).substring(with: hs[0].range), "`")
    XCTAssertEqual(hs[1].kind, .inlineCodeText)
    XCTAssertEqual((text as NSString).substring(with: hs[1].range), "code")
    XCTAssertEqual(hs[2].kind, .inlineCodeDelimiter)
    XCTAssertEqual((text as NSString).substring(with: hs[2].range), "`")
  }

  func testBulletMarkerHighlight() {
    let text = "- item\n12. item"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertEqual(hs.count, 2)
    XCTAssertEqual(hs[0].kind, .listMarker)
    XCTAssertEqual((text as NSString).substring(with: hs[0].range), "- ")
    XCTAssertEqual(hs[1].kind, .listMarker)
    XCTAssertEqual((text as NSString).substring(with: hs[1].range), "12. ")
  }

  func testEmphasisStrongStrikeAndLinks() {
    let text = "This is **bold** and *em* and ~~strike~~ and [OpenAI](https://openai.com)."
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)

    func substrings(of kind: MarkdownHighlightKind) -> [String] {
      hs.filter { $0.kind == kind }.map { (text as NSString).substring(with: $0.range) }
    }

    XCTAssertEqual(substrings(of: .strongText), ["bold"])
    XCTAssertEqual(substrings(of: .emphasisText), ["em"])
    XCTAssertEqual(substrings(of: .strikethroughText), ["strike"])
    XCTAssertEqual(substrings(of: .linkText), ["OpenAI"])
    XCTAssertEqual(substrings(of: .linkURL), ["https://openai.com"])
  }

  func testUnderscoresInsideWordsDoNotBecomeEmphasis() {
    let text = "a_b_c"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertTrue(hs.filter { $0.kind == .emphasisText }.isEmpty)
  }

  func testTaskListCheckbox() {
    let text = "- [x] done"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertTrue(hs.contains { $0.kind == .taskBox(checked: true) && (text as NSString).substring(with: $0.range) == "[x]" })
  }

  func testTableSyntaxHasNoSpecialHighlighting() {
    let text = "| col a | col b |\n| --- | --- |\n| 1 | 2 |"
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    XCTAssertTrue(hs.isEmpty)
  }

  func testBareURLTrimsSentencePunctuation() {
    let text = "See https://openai.com/docs."
    let range = NSRange(location: 0, length: (text as NSString).length)
    let hs = MarkdownHighlighter.highlights(in: text, range: range)
    let urls = hs.filter { $0.kind == .linkURL }.map { (text as NSString).substring(with: $0.range) }
    XCTAssertEqual(urls, ["https://openai.com/docs"])
  }
}
