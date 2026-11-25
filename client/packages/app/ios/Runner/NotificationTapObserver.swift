// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//
// Notices which channel a tapped notification came from, without taking the
// notification delegate away from whoever already had it.
//
// Something else always does have it: firebase_messaging claims
// `UNUserNotificationCenter.delegate` during plugin registration, and its own
// push handling runs from there. So this chains rather than replaces - every
// callback is passed straight on to the delegate that was installed before it,
// and this class's only addition is reading one key out of `userInfo` on the
// way past.
//
// It exists as its own `NSObject` rather than as methods on `AppDelegate`
// because `FlutterAppDelegate` implements these callbacks while declaring them
// in no public header. Swift cannot see them, so it can neither override them
// nor call `super`, and a subclass method with the same selector would shadow
// the engine's own fan-out to plugins with no way to forward. Conforming to
// `UNUserNotificationCenterDelegate` directly is ordinary public API and has
// none of that problem.

import UserNotifications

final class NotificationTapObserver: NSObject, UNUserNotificationCenterDelegate {
  init(next: UNUserNotificationCenterDelegate?, onTap: @escaping (String) -> Void) {
    self.next = next
    self.onTap = onTap
  }

  /// Held strongly, which looks wrong for a delegate and is not.
  ///
  /// `UNUserNotificationCenter.delegate` is itself weak, so the moment this
  /// class takes that slot the previous delegate has lost the one reference
  /// keeping it alive. A weak reference here would let firebase_messaging's
  /// plugin deallocate and take its whole push path with it; a strong one is
  /// what keeps the chain intact. Both ends are app-lifetime singletons, so
  /// there is nothing here to reclaim later anyway.
  ///
  /// Settable because the observer takes the slot at launch, before plugin
  /// registration decides who it should chain to.
  var next: UNUserNotificationCenterDelegate?
  private let onTap: (String) -> Void

  /// A tap on a delivered notification. The channel id is whatever the
  /// notification service extension decrypted out of the sealed envelope and
  /// left in `userInfo`; a push this device could not open carries none, and
  /// tapping it opens the app without moving it, which is what every tap did
  /// before any of this existed.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if let channelId = info[PushEnvelope.channelIdKey] as? String, !channelId.isEmpty {
      onTap(channelId)
    }
    guard let next = next,
      next.responds(
        to: #selector(
          UNUserNotificationCenterDelegate.userNotificationCenter(
            _:didReceive:withCompletionHandler:)))
    else {
      completionHandler()
      return
    }
    next.userNotificationCenter?(
      center, didReceive: response, withCompletionHandler: completionHandler)
  }

  /// Forwarded untouched. A notification arriving while the app is foregrounded
  /// is not a tap and says nothing about where anyone wants to go, so this
  /// class has no opinion on it - but the delegate behind it does, and dropping
  /// the callback would be dropping that.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard let next = next,
      next.responds(
        to: #selector(
          UNUserNotificationCenterDelegate.userNotificationCenter(
            _:willPresent:withCompletionHandler:)))
    else {
      completionHandler([])
      return
    }
    next.userNotificationCenter?(
      center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  /// Forwarded untouched, for the same reason. This one has no completion
  /// handler, so an absent delegate simply means nothing happens.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    openSettingsFor notification: UNNotification?
  ) {
    next?.userNotificationCenter?(center, openSettingsFor: notification)
  }
}
