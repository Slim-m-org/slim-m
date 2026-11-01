// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import Flutter
import UIKit
import UserNotifications

/// The app half of the icon badge; the Dart half is
/// `packages/platform/lib/src/app_badge_channel.dart`, which owns the channel
/// name. The notification service extension sets the badge when a push
/// arrives (`NotificationService/BadgeCount.swift`); this makes it right again
/// whenever the app knows better.
enum AppBadgeChannel {
  static let name = "top.npcserver.slimm/app_badge"

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "sync", let args = call.arguments as? [String: Any],
      let count = args["count"] as? Int
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    let readChannelIds = args["readChannelIds"] as? [String] ?? []
    sync(count: max(count, 0), readChannelIds: Set(readChannelIds))
    result(nil)
  }

  /// Sets the badge and drops delivered notifications of channels that are
  /// read, so the extension's next count starts from what is really unread.
  private static func sync(count: Int, readChannelIds: Set<String>) {
    let center = UNUserNotificationCenter.current()
    if #available(iOS 16.0, *) {
      center.setBadgeCount(count) { _ in }
    } else {
      DispatchQueue.main.async { UIApplication.shared.applicationIconBadgeNumber = count }
    }
    center.getDeliveredNotifications { delivered in
      let stale = delivered.filter { readChannelIds.contains($0.request.content.threadIdentifier) }
      if !stale.isEmpty {
        center.removeDeliveredNotifications(withIdentifiers: stale.map { $0.request.identifier })
      }
    }
  }
}
