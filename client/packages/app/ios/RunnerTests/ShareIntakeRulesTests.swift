// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import XCTest

/// `ShareIntakeRules.swift` is compiled into this target as well as the extension and the app,
/// the same way `BadgeCount.swift` is. These pin the same rules Android's `ShareIntakeRules.kt` holds.
final class ShareIntakeRulesTests: XCTestCase {
  func testAFileNameCannotEscapeItsFolder() {
    XCTAssertEqual(ShareIntakeRules.safeFileName("../../etc/passwd"), "passwd")
    XCTAssertEqual(ShareIntakeRules.safeFileName("a\\b.txt"), "a_b.txt")
    XCTAssertEqual(ShareIntakeRules.safeFileName(".."), "shared")
    XCTAssertEqual(ShareIntakeRules.safeFileName("dir/"), "shared")
    XCTAssertEqual(ShareIntakeRules.safeFileName("  "), "shared")
  }

  func testALongNameKeepsItsExtensionAndWholeCharacters() {
    let name = String(repeating: "\u{00E9}", count: 150) + ".jpeg"
    let capped = ShareIntakeRules.capNameBytes(name)
    XCTAssertLessThanOrEqual(capped.utf8.count, ShareIntakeRules.maxNameBytes)
    XCTAssertTrue(capped.hasSuffix(".jpeg"))
    XCTAssertEqual(ShareIntakeRules.capNameBytes("short.png"), "short.png")
  }

  func testAShareSpendsItsBudget() {
    XCTAssertEqual(ShareIntakeRules.allowedBytes(copiedSoFar: 0), ShareIntakeRules.maxFileBytes)
    let nearlyFull = ShareIntakeRules.maxShareBytes - 10
    XCTAssertEqual(ShareIntakeRules.allowedBytes(copiedSoFar: nearlyFull), 10)
    XCTAssertEqual(ShareIntakeRules.allowedBytes(copiedSoFar: ShareIntakeRules.maxShareBytes + 5), 0)
  }

  func testSharesFoldIntoOne() {
    let merged = ShareIntakeRules.mergeShares([
      ["files": [["path": "a"]], "text": "one", "unreadable": 1, "tooLarge": 0],
      ["files": [["path": "b"]], "text": "two", "unreadable": 0, "tooLarge": 2],
    ])
    XCTAssertEqual((merged["files"] as? [Any])?.count, 2)
    XCTAssertEqual(merged["text"] as? String, "one\ntwo")
    XCTAssertEqual(merged["unreadable"] as? Int, 1)
    XCTAssertEqual(merged["tooLarge"] as? Int, 2)
  }

  func testNoTextMergesToNull() {
    let merged = ShareIntakeRules.mergeShares([["files": [Any]()]])
    XCTAssertTrue(merged["text"] is NSNull)
  }

  func testABatchAgesFromItsName() {
    let name = ShareIntakeRules.batchName(nowMillis: 1_000, unique: "abc")
    XCTAssertEqual(ShareIntakeRules.batchMillis(name), 1_000)
    let day = ShareIntakeRules.keepMillis
    XCTAssertFalse(ShareIntakeRules.batchIsExpired(name, hasManifest: true, nowMillis: 1_000 + day))
    XCTAssertTrue(ShareIntakeRules.batchIsExpired(name, hasManifest: true, nowMillis: 1_001 + day))
  }

  func testAnUnfinishedBatchGoesSooner() {
    let name = ShareIntakeRules.batchName(nowMillis: 0, unique: "abc")
    let hour = ShareIntakeRules.unfinishedMillis
    XCTAssertTrue(ShareIntakeRules.batchIsExpired(name, hasManifest: false, nowMillis: hour + 1))
    XCTAssertFalse(ShareIntakeRules.batchIsExpired(name, hasManifest: true, nowMillis: hour + 1))
  }

  func testAFolderNobodyNamedIsNeverKept() {
    XCTAssertTrue(ShareIntakeRules.batchIsExpired("stray", hasManifest: true, nowMillis: 0))
  }
}
