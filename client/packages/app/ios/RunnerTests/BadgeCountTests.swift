// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import XCTest

/// `BadgeCount.swift` is compiled into this target as well as the extension,
/// the same way `NotificationSound.swift` is.
final class BadgeCountTests: XCTestCase {
  func testTwoMessagesInOneChannelCountOnce() {
    let count = BadgeCount.unreadChannels(
      deliveredThreads: ["a", "a"], currentThread: "a")
    XCTAssertEqual(count, 1)
  }

  func testANewChannelAddsToWhatIsAlreadyDelivered() {
    let count = BadgeCount.unreadChannels(
      deliveredThreads: ["a", "b"], currentThread: "c")
    XCTAssertEqual(count, 3)
  }

  func testAnEmptyThreadIdIsIgnored() {
    let count = BadgeCount.unreadChannels(
      deliveredThreads: ["", "a"], currentThread: nil)
    XCTAssertEqual(count, 1)
  }

  func testThePushThatIsBeingShownAlwaysCounts() {
    let count = BadgeCount.unreadChannels(deliveredThreads: [], currentThread: nil)
    XCTAssertEqual(count, 1)
  }
}
