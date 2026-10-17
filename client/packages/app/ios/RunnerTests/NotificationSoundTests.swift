// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import UserNotifications
import XCTest

/// `PushEnvelope` and the crypto sources are compiled into this test target
/// as well as into the extension - see `PushSealedBoxTests.swift`'s own doc
/// comment - and `NotificationSound.swift` is compiled the same way, so this
/// reaches everything under test with no module boundary to cross.
///
/// A fake `CallActivityChecking` stands in for `CXCallObserver`, the same
/// shape `VoipCallHandlerTests.swift`'s `RecordingProvider` uses for the
/// CallKit APIs a plain XCTest cannot exercise for real.
private struct FakeCallActivity: CallActivityChecking {
  var hasActiveCall: Bool
}

final class NotificationSoundTests: XCTestCase {
  private func envelope(sender: String?, body: String?, channel: String?) -> PushEnvelope {
    PushEnvelope(
      domain: PushEnvelope.expectedDomain,
      version: PushEnvelope.expectedVersion,
      channelId: "c1",
      messageId: "m1",
      sentAt: nil,
      sender: sender,
      channel: channel,
      body: body
    )
  }

  func testALiveCallSilencesEvenAFullyReadableEnvelope() {
    let full = envelope(sender: "Ada", body: "hi", channel: "general")
    let decision = NotificationSound.decide(
      for: full, callActivity: FakeCallActivity(hasActiveCall: true))
    XCTAssertEqual(decision, .silence)
  }

  func testALiveCallSilencesAnEnvelopeThatFailedToDecodeToo() {
    // The mission this exists for: a push this extension could not even
    // read must still not sound over a call in progress.
    let decision = NotificationSound.decide(
      for: nil, callActivity: FakeCallActivity(hasActiveCall: true))
    XCTAssertEqual(decision, .silence)
  }

  func testAContentFreeEnvelopeLeavesTheSoundUnset() {
    let bare = envelope(sender: nil, body: nil, channel: nil)
    let decision = NotificationSound.decide(
      for: bare, callActivity: FakeCallActivity(hasActiveCall: false))
    XCTAssertEqual(decision, .leaveUnset)
  }

  func testNoEnvelopeAtAllLeavesTheSoundUnset() {
    let decision = NotificationSound.decide(
      for: nil, callActivity: FakeCallActivity(hasActiveCall: false))
    XCTAssertEqual(decision, .leaveUnset)
  }

  func testANamedChannelPlaysTheGroupMessageSound() {
    let named = envelope(sender: "Ada", body: "hi", channel: "general")
    let decision = NotificationSound.decide(
      for: named, callActivity: FakeCallActivity(hasActiveCall: false))
    XCTAssertEqual(decision, .named("group_message.wav"))
  }

  func testNoChannelNamePlaysTheDirectMessageSound() {
    // A DM and a thread reply both carry no channel name, per
    // PushEnvelope.applied(to:)'s own doc comment - the wire cannot tell
    // them apart, and neither can this.
    let dmShaped = envelope(sender: "Ada", body: "hi", channel: nil)
    let decision = NotificationSound.decide(
      for: dmShaped, callActivity: FakeCallActivity(hasActiveCall: false))
    XCTAssertEqual(decision, .named("direct_message.wav"))
  }

  func testAnEmptyChannelStringIsTreatedTheSameAsNoChannel() {
    let blankChannel = envelope(sender: "Ada", body: "hi", channel: "")
    let decision = NotificationSound.decide(
      for: blankChannel, callActivity: FakeCallActivity(hasActiveCall: false))
    XCTAssertEqual(decision, .named("direct_message.wav"))
  }

  func testApplySilenceClearsWhateverSoundWasAlreadySet() {
    let content = UNMutableNotificationContent()
    content.sound = UNNotificationSound.default
    NotificationSound.apply(.silence, to: content)
    XCTAssertNil(content.sound)
  }

  /// `UNNotificationSound` carries no public way to read a name back off an
  /// instance, so this checks identity - the untouched original reference -
  /// rather than equality, which the type may not even implement.
  func testApplyLeaveUnsetTouchesNothing() {
    let content = UNMutableNotificationContent()
    let original = UNNotificationSound.default
    content.sound = original
    NotificationSound.apply(.leaveUnset, to: content)
    XCTAssertTrue(content.sound === original, "leaveUnset must not reassign content.sound")
  }

  func testApplyNamedReplacesWhateverSoundWasThereWithSomething() {
    let content = UNMutableNotificationContent()
    let original = UNNotificationSound.default
    content.sound = original
    NotificationSound.apply(.named("direct_message.wav"), to: content)
    XCTAssertNotNil(content.sound)
    XCTAssertFalse(content.sound === original, "named must replace the sound, not keep the old one")
  }

  func testAMentionPlaysTheMentionSoundEvenWithoutAPreview() {
    var mention = envelope(sender: nil, body: nil, channel: nil)
    mention.kind = PushEnvelope.mentionKind
    let decision = NotificationSound.decide(
      for: mention, callActivity: FakeCallActivity(hasActiveCall: false))
    XCTAssertEqual(decision, .named("mention.wav"))
  }

  func testALiveCallSilencesAMentionToo() {
    var mention = envelope(sender: "Ada", body: "hi @you", channel: "general")
    mention.kind = PushEnvelope.mentionKind
    let decision = NotificationSound.decide(
      for: mention, callActivity: FakeCallActivity(hasActiveCall: true))
    XCTAssertEqual(decision, .silence)
  }

  func testASignInAlertNamesTheDevice() throws {
    let plaintext = Array(
      #"{"domain":"slim-m.push.v1","version":1,"kind":"security","event":"new_device_sign_in","signed_in_at":1,"device_name":"Pixel 9"}"#
        .utf8)
    let decoded = try XCTUnwrap(PushEnvelope.decode(plaintext))
    let content = decoded.applied(to: UNMutableNotificationContent())
    XCTAssertEqual(content.title, "New sign-in")
    XCTAssertEqual(content.body, "Pixel 9 signed in to your account.")
  }
}
