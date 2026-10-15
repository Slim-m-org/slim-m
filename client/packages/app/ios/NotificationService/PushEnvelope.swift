// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//
// The plaintext inside a sealed push envelope, and what a lock screen should
// make of it.
//
// The authority on this shape is crates/slimm-server/src/push/envelope.rs.
// Everything past the routing fields is optional there: a device that did not
// ask for content, or one whose preview would not fit the envelope budget,
// gets the same envelope with `sender`, `channel` and `body` simply absent.
//
// `sentAt` is the defense against a hostile relay retaining a sealed payload
// and re-delivering it later: without it, a preview carrying real message
// text would resurface on a lock screen at an arbitrary later time with
// nothing here able to tell a fresh push from a replayed one. `isStale`
// refuses to render a preview once `sentAt` is old enough, falling back to
// whatever the relay's own generic placeholder already said - never to no
// notification at all, matching every other failure path in this extension.
// Routing is unaffected either way: a stale replay still opens the right
// channel when tapped, the same as a device that opted out of content ever
// did.
//
// `sentAt` is optional because it is additive on the wire: an envelope sealed
// by a server built before this field existed carries none, and that must
// read as "not stale", never as a reason to refuse an otherwise-good preview.

import Foundation
import UserNotifications

struct PushEnvelope: Decodable {
  /// Domain separation, so a payload sealed to this device in some other
  /// context can never be reinterpreted as a notification.
  static let expectedDomain = "slim-m.push.v1"
  static let expectedVersion = 1

  /// The keys iOS reads a tapped notification's routing back out of. Set by
  /// [applied(to:)] on the decrypted copy, which never leaves this device -
  /// the relay and APNs only ever saw the sealed blob these came out of.
  static let channelIdKey = "slimm_channel_id"
  static let messageIdKey = "slimm_message_id"

  let domain: String
  let version: Int
  let channelId: String?
  let messageId: String?
  let sentAt: Int64?
  let sender: String?
  let channel: String?
  let body: String?
  /// Defaulted so a test can build a message envelope without naming them.
  var kind: String? = nil
  var event: String? = nil
  var deviceName: String? = nil

  static let mentionKind = "mention"
  static let securityKind = "security"
  static let newDeviceSignInEvent = "new_device_sign_in"

  /// Spelled out because two of these are snake_case on the wire. The
  /// authority is the `PushEnvelope` struct in
  /// crates/slimm-server/src/push/envelope.rs.
  enum CodingKeys: String, CodingKey {
    case domain
    case version
    case channelId = "channel_id"
    case messageId = "message_id"
    case sentAt = "sent_at"
    case sender
    case channel
    case body
    case kind
    case event
    case deviceName = "device_name"
  }

  /// Decodes, or nil for anything this build should not act on. An unknown
  /// domain or version is refused rather than best-guessed: the generic
  /// string a newer server's envelope falls back to is correct, where a
  /// misread field would put the wrong words on someone's lock screen.
  static func decode(_ plaintext: [UInt8]) -> PushEnvelope? {
    guard let envelope = try? JSONDecoder().decode(
      PushEnvelope.self,
      from: Data(plaintext)
    ) else { return nil }

    guard envelope.domain == expectedDomain,
      envelope.version == expectedVersion
    else { return nil }

    return envelope
  }

  /// Whether there is anything here worth replacing the generic alert with.
  /// A content-free envelope carries the routing fields alone, and rewriting
  /// "New message" into an empty title would be strictly worse than leaving
  /// it be.
  /// An empty body is held to the same bar as an empty sender, and for the
  /// same reason: a message carrying only an attachment has no text at all,
  /// so a preview built from it would replace "New message" with a sender's
  /// name above nothing - less than the placeholder said, not more.
  var hasPreview: Bool {
    guard let sender = sender, !sender.isEmpty else { return false }
    guard let body = body, !body.isEmpty else { return false }
    return true
  }

  /// Generous headroom over ordinary delivery latency - seconds, even under
  /// APNs backpressure - while still refusing a payload a hostile relay held
  /// back and replayed well after the fact.
  static let staleAfterMs: Int64 = 10 * 60 * 1000

  /// True only when `sentAt` is present and old enough that a replayed
  /// payload should not be trusted with real text on a lock screen. Absent
  /// is never stale - there is nothing to compare against, and this file's
  /// own module doc states the wire-compatibility rule that must hold here:
  /// an old envelope with no `sentAt` still renders.
  func isStale(now: Date = Date()) -> Bool {
    guard let sentAt else { return false }
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    return nowMs - sentAt > Self.staleAfterMs
  }

  /// Rewrites the placeholder in place, leaving everything the relay set -
  /// sound and badge alone, and groups by channel.
  ///
  /// The channel becomes a subtitle rather than part of the title, so a
  /// name too long for one line elides its own line instead of pushing the
  /// sender off the screen. A DM and a thread reply both carry no channel
  /// name at all (the server sends none), so those show the sender alone,
  /// which is already the whole of where it came from.
  ///
  /// Routing is attached whether or not there is a preview, and that split
  /// is deliberate: `channel_id` rides in every envelope, while a preview is
  /// a per-device opt-in, so a device that shows the generic placeholder must
  /// still open the right channel when somebody taps it. A stale envelope
  /// gets the identical treatment: routing is real regardless of age, only
  /// the preview text is what a replay could be lying about.
  func applied(
    to content: UNMutableNotificationContent,
    now: Date = Date()
  ) -> UNMutableNotificationContent {
    attachRouting(to: content)
    if kind == Self.securityKind, event == Self.newDeviceSignInEvent,
      let deviceName, !deviceName.isEmpty
    {
      // Matches the in-app banner's wording.
      content.title = "New sign-in"
      content.body = "\(deviceName) signed in to your account."
      return content
    }
    guard hasPreview, !isStale(now: now), let sender = sender, let body = body else {
      return content
    }
    content.title = sender
    if let channel, !channel.isEmpty {
      content.subtitle = "#\(channel)"
    }
    content.body = body
    return content
  }

  /// Copies the routing ids into `userInfo` so the app can read them when
  /// this notification is tapped. `userInfo` is merged rather than replaced:
  /// the sealed `payload` and the relay's `kind` both live there too, and
  /// this must not be the thing that drops them.
  ///
  /// The channel id doubles as the thread identifier so a busy channel
  /// groups into one stack on the lock screen instead of one per message.
  private func attachRouting(to content: UNMutableNotificationContent) {
    var info = content.userInfo
    if let channelId, !channelId.isEmpty {
      info[Self.channelIdKey] = channelId
      content.threadIdentifier = channelId
    }
    if let messageId, !messageId.isEmpty { info[Self.messageIdKey] = messageId }
    content.userInfo = info
  }
}
