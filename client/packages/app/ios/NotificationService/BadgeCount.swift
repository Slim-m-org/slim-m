// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Foundation

/// The app icon badge a push should leave behind: how many channels have a
/// notification waiting, which is what the in-app rail counts too.
///
/// A push only exists for a channel the recipient has not muted, so counting
/// the channels that still have a delivered notification never adds a muted
/// one. The app trims delivered notifications for channels it has since seen
/// read, which is how a read on another device is reflected the next time the
/// app opens.
enum BadgeCount {
  /// Distinct non-empty channel ids among `deliveredThreads`, plus
  /// `currentThread` when it is not one of them already.
  static func unreadChannels(deliveredThreads: [String], currentThread: String?) -> Int {
    var channels = Set(deliveredThreads.filter { !$0.isEmpty })
    if let currentThread, !currentThread.isEmpty { channels.insert(currentThread) }
    return max(channels.count, 1)
  }
}
