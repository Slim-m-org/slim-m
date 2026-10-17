// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//
// Which sound, if any, a decorated push should play - and the one rule that
// overrides every other answer: a call already in progress must not be
// stepped on by a chime.
//
// The sealed envelope's `kind` (`PushKind` in crates/slimm-server/src/push/
// envelope.rs) says `mention` for a message that mentions the reader, which
// gets the mention sound. Otherwise `channel` decides: present for a named
// channel, absent for a DM or a thread reply (see PushEnvelope's own doc
// comment on `applied(to:)`).

import CallKit
import Foundation
import UserNotifications

enum NotificationSound {
  /// What to do with `content.sound`, kept as a value rather than acted on
  /// immediately so `decide` stays pure and testable with no `UNMutable...`
  /// object in play at all.
  enum Decision: Equatable {
    /// A call is already up; nothing should sound over it.
    case silence
    /// Not enough is known to choose - a content-free envelope, or one that
    /// failed to decode - so whatever the push already carried stands.
    case leaveUnset
    case named(String)
  }

  /// Bundled at the top level of the Runner app's own bundle by
  /// `project.pbxproj`'s Audio group, generated from the same
  /// `assets/audio/notifications/*.wav` `audio-ci` diffs; must name a real
  /// file there or `UNNotificationSound(named:)` silently falls back to the
  /// platform default with nothing failing anywhere.
  private static let directMessage = "direct_message.wav"
  private static let groupMessage = "group_message.wav"
  private static let mention = "mention.wav"

  static func decide(
    for envelope: PushEnvelope?,
    callActivity: CallActivityChecking
  ) -> Decision {
    guard !callActivity.hasActiveCall else { return .silence }
    guard let envelope else { return .leaveUnset }
    if envelope.kind == PushEnvelope.mentionKind { return .named(mention) }
    guard envelope.hasPreview else { return .leaveUnset }
    if let channel = envelope.channel, !channel.isEmpty { return .named(groupMessage) }
    return .named(directMessage)
  }

  static func apply(_ decision: Decision, to content: UNMutableNotificationContent) {
    switch decision {
    case .silence:
      content.sound = nil
    case .leaveUnset:
      break
    case .named(let fileName):
      content.sound = UNNotificationSound(named: UNNotificationSoundName(fileName))
    }
  }
}

/// A seam over "is a call live right now," the same shape `CallReporting`
/// and `CallRequesting` already use in the Runner target for CallKit APIs a
/// plain XCTest cannot exercise for real.
protocol CallActivityChecking {
  var hasActiveCall: Bool { get }
}

/// `CXCallObserver().calls` reads CallKit's already-known state the instant
/// it is constructed - it does not wait for a delegate callback - so this
/// stays synchronous, matching every other read this extension does; see
/// NotificationService.swift's own doc comment on why nothing here waits.
/// Needs no App Group and no portal capability, unlike the push private key
/// this extension already reads through PushKeychain: linking CallKit is
/// enough, the same way VoipCallHandler.swift and VoiceCallReporter.swift
/// already link it in the Runner target with no extra entitlement.
///
/// Reports a call CallKit is tracking for any app, including the system
/// Phone app, since the question is "would a chime step on audio the user
/// is already hearing," not only a call this app itself joined or reported.
///
/// Unverified on a real device, the same evidentiary bar this client's other
/// untested-on-device iOS surfaces already carry: reasoned from Apple's
/// documented `CXCallObserver` semantics, not run against a live call.
struct CallKitActivityChecker: CallActivityChecking {
  var hasActiveCall: Bool {
    CXCallObserver().calls.contains { !$0.hasEnded }
  }
}
