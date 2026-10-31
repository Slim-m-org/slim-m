// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//
// The Notification Service Extension: given a push before iOS shows it, it
// opens the sealed envelope and replaces the relay's generic "New message"
// with the real sender and text, and decides what - if anything - should
// sound. See NotificationSound.swift for that decision.
//
// The relay never sees any of that. It forwards a base64 blob it cannot read
// (crates/slimm-server/src/push/envelope.rs) and sets `mutable-content` so
// this process gets a chance at it; the fixed placeholder exists precisely so
// a device without this extension still shows something.
//
// Every failure path here shows that placeholder instead. A notification is
// worth showing without its content and is worth nothing at all if it never
// arrives, and this process has a hard time budget and a small memory one, so
// nothing here waits on anything, retries, or reaches the network - including
// the sound decision, which reads CXCallObserver's already-known state
// rather than waiting on a delegate callback.

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  /// The key the relay puts the sealed envelope under, alongside `kind`, as
  /// a top-level custom field beside `aps`. See the relay's
  /// `internal/apns/apns.go`.
  private static let payloadKey = "payload"

  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var placeholder: UNNotificationContent?

  /// Not injected: this class is never compiled into `RunnerTests` (only
  /// `NotificationSound.swift`, `PushEnvelope.swift` and the crypto sources
  /// are, the same way `PushSealedBoxTests.swift`'s own doc comment already
  /// explains for those), so there is no test host for a seam here to serve.
  /// `NotificationSound.decide` is what carries the tested logic; this is
  /// one concrete reader of its answer.
  private let callActivity: CallActivityChecking = CallKitActivityChecker()

  /// Set by `decorated`, so `withSound` can reuse the one envelope
  /// `decode` already opened rather than opening the sealed box again.
  private var decodedEnvelope: PushEnvelope?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    placeholder = request.content

    // Answered on this call rather than asynchronously: a keychain read,
    // one sealed box and one CXCallObserver read are the whole of the
    // work, so there is nothing to wait for and no reason to spend any of
    // the budget waiting.
    let content = withSound(decorated(request.content) ?? request.content)
    withBadge(content) { [weak self] badged in self?.deliver(badged) }
  }

  /// iOS calls this when the budget runs out, and whatever it is handed is
  /// what the user sees. Reaching it at all would mean `didReceive` never
  /// answered, so the placeholder is the only honest thing left - sound
  /// decided fresh even here, since a call in progress is worth silencing
  /// on any path out of this extension, not only the ordinary one.
  override func serviceExtensionTimeWillExpire() {
    guard let content = placeholder else { return }
    deliver(withSound(content))
  }

  /// The handler must be called exactly once; clearing it is what makes a
  /// later `serviceExtensionTimeWillExpire` a no-op rather than a second
  /// call.
  private func deliver(_ content: UNNotificationContent) {
    guard let handler = contentHandler else { return }
    contentHandler = nil
    handler(content)
  }

  /// Nil for anything at all that stops this envelope being readable: no
  /// payload, no key on this device yet, a locked keychain, ciphertext
  /// sealed to some other key, or an envelope from a version this build does
  /// not know.
  ///
  /// An envelope that opens but carries no preview is deliberately not nil:
  /// it still names the channel the push came from, and attaching that is
  /// what lets a tap on the generic placeholder open the right channel. See
  /// `PushEnvelope.applied(to:)`.
  private func decorated(_ content: UNNotificationContent) -> UNNotificationContent? {
    guard let encoded = content.userInfo[Self.payloadKey] as? String,
      let sealed = Data(base64Encoded: encoded),
      let privateKey = PushKeychain.privateKey(),
      let plaintext = PushSealedBox.open([UInt8](sealed), privateKey: privateKey),
      let envelope = PushEnvelope.decode(plaintext),
      let mutable = content.mutableCopy() as? UNMutableNotificationContent
    else { return nil }

    decodedEnvelope = envelope
    return envelope.applied(to: mutable)
  }

  /// Sets the icon badge to the channels with a notification waiting. Falls
  /// back to the content as it is if the answer never comes: a notification
  /// without a badge is worth more than one that arrives late.
  private func withBadge(
    _ content: UNNotificationContent,
    completion: @escaping (UNNotificationContent) -> Void
  ) {
    guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
      completion(content)
      return
    }
    UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
      mutable.badge = NSNumber(
        value: BadgeCount.unreadChannels(
          deliveredThreads: delivered.map { $0.request.content.threadIdentifier },
          currentThread: mutable.threadIdentifier))
      completion(mutable)
    }
  }

  /// Chooses and attaches a sound, after `decorated` has had its chance to
  /// decode an envelope - applied whether or not that succeeded, since a
  /// live call must silence a push this extension could not even read, not
  /// only the ones it could.
  private func withSound(_ content: UNNotificationContent) -> UNNotificationContent {
    guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
    let decision = NotificationSound.decide(for: decodedEnvelope, callActivity: callActivity)
    NotificationSound.apply(decision, to: mutable)
    return mutable
  }
}
