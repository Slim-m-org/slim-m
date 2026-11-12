// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import XCTest

/// The evidence that the Notification Service Extension's hand-written
/// sealed-box implementation is right.
///
/// It is hand-written because CryptoKit has one of the five primitives a
/// libsodium sealed box needs (see PushSealedBox.swift for that reasoning),
/// and reasoning about crypto is not the same as running it. So this opens
/// real ciphertext: `push_envelope_cases.json` is written by
/// `crates/slimm-server/tests/it_notify/push_envelope_fixture.rs` using the same
/// `crypto_box` version the server actually seals with, and a Rust test
/// asserts the same file still opens with the server's own crate. If the two
/// implementations ever disagree, one of the two fails.
///
/// The crypto sources are compiled into this test target as well as into the
/// extension, so nothing here reaches across a module boundary.
final class PushSealedBoxTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Case: Decodable {
      let name: String
      let plaintext: String
      let sealedBase64: String

      enum CodingKeys: String, CodingKey {
        case name
        case plaintext
        case sealedBase64 = "sealed_base64"
      }
    }

    let recipientSecretKeyBase64: String
    let cases: [Case]

    enum CodingKeys: String, CodingKey {
      case recipientSecretKeyBase64 = "recipient_secret_key_base64"
      case cases
    }
  }

  private func loadFixture() throws -> Fixture {
    let bundle = Bundle(for: type(of: self))
    let url = try XCTUnwrap(
      bundle.url(forResource: "push_envelope_cases", withExtension: "json"),
      "push_envelope_cases.json is not in the test bundle's resources"
    )
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  private func privateKey(_ fixture: Fixture) throws -> [UInt8] {
    let decoded = try XCTUnwrap(Data(base64Encoded: fixture.recipientSecretKeyBase64))
    return [UInt8](decoded)
  }

  /// The whole point. Every case, including the ones chosen for where the
  /// keystream crosses a block boundary rather than for realism.
  func testOpensEveryEnvelopeTheServerSealed() throws {
    let fixture = try loadFixture()
    let key = try privateKey(fixture)
    XCTAssertFalse(fixture.cases.isEmpty, "an empty fixture would pass vacuously")

    for testCase in fixture.cases {
      let sealed = try XCTUnwrap(
        Data(base64Encoded: testCase.sealedBase64),
        "\(testCase.name): sealed_base64 is not base64"
      )
      let opened = try XCTUnwrap(
        PushSealedBox.open([UInt8](sealed), privateKey: key),
        "\(testCase.name): did not open"
      )
      XCTAssertEqual(
        String(decoding: opened, as: UTF8.self),
        testCase.plaintext,
        "\(testCase.name): opened to the wrong plaintext"
      )
    }
  }

  /// A tag check that passed on modified ciphertext would be worse than no
  /// tag check, so this flips one bit of every byte position in turn on the
  /// smallest non-empty case and asserts each is refused.
  func testRefusesTamperedCiphertext() throws {
    let fixture = try loadFixture()
    let key = try privateKey(fixture)
    let testCase = try XCTUnwrap(fixture.cases.first { !$0.plaintext.isEmpty })
    let original = [UInt8](try XCTUnwrap(Data(base64Encoded: testCase.sealedBase64)))

    for index in 0..<original.count {
      var tampered = original
      tampered[index] ^= 0x01
      XCTAssertNil(
        PushSealedBox.open(tampered, privateKey: key),
        "\(testCase.name): byte \(index) was changed and it opened anyway"
      )
    }
  }

  /// Sealed to somebody else, which is what every notification for another
  /// device on the same relay is.
  func testRefusesAnEnvelopeSealedToAnotherKey() throws {
    let fixture = try loadFixture()
    var other = try privateKey(fixture)
    other[0] ^= 0xff
    let testCase = try XCTUnwrap(fixture.cases.first)
    let sealed = [UInt8](try XCTUnwrap(Data(base64Encoded: testCase.sealedBase64)))

    XCTAssertNil(PushSealedBox.open(sealed, privateKey: other))
  }

  /// Truncation must be refused rather than read past. A sealed box shorter
  /// than its own ephemeral key and tag has no ciphertext at all, and the
  /// empty case is exactly that length, so the boundary is real.
  func testRefusesTruncatedInput() throws {
    let fixture = try loadFixture()
    let key = try privateKey(fixture)

    for length in 0..<48 {
      XCTAssertNil(
        PushSealedBox.open([UInt8](repeating: 0, count: length), privateKey: key),
        "a \(length)-byte input is too short to be a sealed box"
      )
    }
  }

  /// BLAKE2b against RFC 7693's own appendix A vector, so a nonce that came
  /// out wrong points at the hash rather than at the whole construction.
  func testBlake2bMatchesTheSpecificationVector() {
    let digest = Blake2b.hash(Array("abc".utf8), digestLength: 64)
    let expected =
      "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
      + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
    XCTAssertEqual(hex(digest), expected)
  }

  /// The 24-byte digest length the sealed box actually uses, which is a
  /// different parameter block from the 64-byte one above and so a genuinely
  /// separate case rather than a prefix of it.
  func testBlake2bTruncatedDigestIsNotJustAPrefix() {
    let short = Blake2b.hash(Array("abc".utf8), digestLength: 24)
    let long = Blake2b.hash(Array("abc".utf8), digestLength: 64)
    XCTAssertEqual(short.count, 24)
    XCTAssertNotEqual(short, Array(long[0..<24]))
  }

  /// A message carrying only an attachment has no text, so a preview built
  /// from it would put a sender's name above an empty body - strictly less
  /// than the "New message" placeholder it replaced.
  ///
  /// `hasPreview` already held the sender to this bar and checked only that
  /// the body was present, so an empty one passed. Lives in this file rather
  /// than its own because `PushEnvelope.swift` is already compiled into this
  /// test target; a new file means editing `project.pbxproj`, which cannot be
  /// verified anywhere but a macOS runner.
  func testAnAttachmentOnlyMessageKeepsThePlaceholder() throws {
    let envelope = try decodeEnvelope(sender: "Nick", body: "")
    XCTAssertFalse(
      envelope.hasPreview,
      "an empty body must not replace the generic alert")
  }

  /// `hasPreview` being false is not itself the guarantee - `applied(to:)` has
  /// to actually consult it. It did not, once: the old guard unwrapped
  /// `sender`/`body` for nil alone, so an envelope with an empty (not nil)
  /// body still passed and overwrote the placeholder with a sender's name
  /// above nothing.
  func testAnAttachmentOnlyMessageIsNotAppliedToTheContent() throws {
    let envelope = try decodeEnvelope(sender: "Nick", body: "")
    let content = UNMutableNotificationContent()
    content.title = "New message"
    let applied = envelope.applied(to: content)
    XCTAssertEqual(
      applied.title, "New message",
      "an empty body must not overwrite the placeholder title")
  }

  func testARealBodyIsStillPreviewed() throws {
    let envelope = try decodeEnvelope(sender: "Nick", body: "hello")
    XCTAssertTrue(
      envelope.hasPreview,
      "a real body must still be previewed, or this guard turned it off")
  }

  /// The whole point of the staleness gate: a payload sealed too long ago to
  /// trust must fall back to the placeholder rather than show real text -
  /// exactly the behavior a hostile relay retaining and replaying a payload
  /// would otherwise defeat.
  func testAStalePayloadDoesNotShowAPreview() throws {
    let now = Date()
    let elevenMinutesAgo = now.addingTimeInterval(-11 * 60)
    let envelope = try decodeEnvelope(
      sender: "Nick", body: "hello", sentAt: epochMs(elevenMinutesAgo))
    XCTAssertTrue(envelope.isStale(now: now))

    let content = UNMutableNotificationContent()
    content.title = "New message"
    let applied = envelope.applied(to: content, now: now)
    XCTAssertEqual(
      applied.title, "New message",
      "a stale payload must not overwrite the placeholder title")
    XCTAssertTrue(
      applied.body.isEmpty,
      "a stale payload must not carry its body onto the lock screen")
  }

  /// The boundary itself must not be refused - only strictly past it counts
  /// as stale, or the window would silently be shorter than documented.
  func testAPayloadExactlyAtTheStaleBoundaryIsNotRefused() throws {
    let now = Date()
    let atTheBoundary = now.addingTimeInterval(-Double(PushEnvelope.staleAfterMs) / 1000)
    let envelope = try decodeEnvelope(
      sender: "Nick", body: "hello", sentAt: epochMs(atTheBoundary))
    XCTAssertFalse(envelope.isStale(now: now))
  }

  func testAFreshPayloadIsNotStaleAndIsPreviewed() throws {
    let now = Date()
    let envelope = try decodeEnvelope(sender: "Nick", body: "hello", sentAt: epochMs(now))
    XCTAssertFalse(envelope.isStale(now: now))

    let applied = envelope.applied(to: UNMutableNotificationContent(), now: now)
    XCTAssertEqual(applied.title, "Nick")
    XCTAssertEqual(applied.body, "hello")
  }

  /// The wire-compatibility rule this whole feature depends on: an envelope
  /// sealed by a server built before `sent_at` existed must keep rendering,
  /// today and years from now, since "absent" and "just sealed" must never be
  /// confused with "ancient".
  func testAnEnvelopeWithNoSentAtIsNeverStaleRegardlessOfHowLateItIsRead() throws {
    let envelope = try decodeEnvelope(sender: "Nick", body: "hello", sentAt: nil)
    XCTAssertNil(envelope.sentAt)
    XCTAssertFalse(envelope.isStale())

    let farFuture = Date().addingTimeInterval(365 * 24 * 60 * 60)
    XCTAssertFalse(
      envelope.isStale(now: farFuture),
      "absence of sent_at must not be read as staleness at any later read time")

    let applied = envelope.applied(to: UNMutableNotificationContent())
    XCTAssertEqual(applied.title, "Nick")
  }

  /// Routing must survive a refused preview exactly as it survives an
  /// opted-out device: `channel_id`/`message_id` are real regardless of what
  /// the age check decided about the text.
  func testRoutingIsAttachedEvenWhenThePreviewIsRefusedForStaleness() throws {
    let now = Date()
    let elevenMinutesAgo = now.addingTimeInterval(-11 * 60)
    let envelope = try decodeEnvelope(
      sender: "Nick", body: "hello", sentAt: epochMs(elevenMinutesAgo),
      channelId: "channel-1", messageId: "message-1")

    let applied = envelope.applied(to: UNMutableNotificationContent(), now: now)
    XCTAssertEqual(applied.userInfo[PushEnvelope.channelIdKey] as? String, "channel-1")
    XCTAssertEqual(applied.userInfo[PushEnvelope.messageIdKey] as? String, "message-1")
    XCTAssertNotEqual(applied.title, "Nick", "the stale preview itself must still be refused")
  }

  /// Notifications for one channel must group into a single lock-screen
  /// stack, with or without a preview, and one with no channel stays ungrouped.
  func testChannelIdBecomesTheThreadIdentifier() throws {
    let previewed = try decodeEnvelope(sender: "Nick", body: "hi", channelId: "channel-1")
    XCTAssertEqual(
      previewed.applied(to: UNMutableNotificationContent()).threadIdentifier, "channel-1")

    let placeholder = try decodeEnvelope(sender: "", body: "", channelId: "channel-2")
    XCTAssertEqual(
      placeholder.applied(to: UNMutableNotificationContent()).threadIdentifier, "channel-2")

    let noChannel = try decodeEnvelope(sender: "Nick", body: "hi")
    XCTAssertEqual(noChannel.applied(to: UNMutableNotificationContent()).threadIdentifier, "")
  }

  /// The real, fixture-driven end of this: an envelope actually sealed by
  /// `crypto_box` with no `sent_at` field at all (the exact bytes a
  /// pre-this-field server produced) still opens and still previews, proving
  /// the wire-compatibility rule end to end rather than only against a
  /// hand-written JSON literal.
  func testTheFixturesPreSentAtCaseStillOpensAndPreviews() throws {
    let fixture = try loadFixture()
    let key = try privateKey(fixture)
    let testCase = try XCTUnwrap(
      fixture.cases.first { $0.name == "a pre-sent_at envelope from an older server" },
      "the fixture generator's own case name changed; see push_envelope_fixture.rs")
    let sealed = [UInt8](try XCTUnwrap(Data(base64Encoded: testCase.sealedBase64)))

    let opened = try XCTUnwrap(PushSealedBox.open(sealed, privateKey: key))
    let envelope = try XCTUnwrap(PushEnvelope.decode(opened))
    XCTAssertNil(envelope.sentAt)
    XCTAssertFalse(envelope.isStale())
    XCTAssertTrue(envelope.hasPreview)
  }

  /// Field names match `push/envelope.rs`'s own serialization, which carries
  /// no serde rename - so Swift's default `Decodable` keys are the property
  /// names, and there are no `CodingKeys` to consult beyond the snake_case
  /// ones `PushEnvelope.swift` itself already declares.
  private func decodeEnvelope(
    sender: String,
    body: String,
    sentAt: Int64? = nil,
    channelId: String? = nil,
    messageId: String? = nil
  ) throws -> PushEnvelope {
    var fields = [
      "\"domain\":\"slim-m.push.v1\"",
      "\"version\":1",
      "\"sender\":\"\(sender)\"",
      "\"body\":\"\(body)\"",
    ]
    if let sentAt { fields.append("\"sent_at\":\(sentAt)") }
    if let channelId { fields.append("\"channel_id\":\"\(channelId)\"") }
    if let messageId { fields.append("\"message_id\":\"\(messageId)\"") }
    let json = "{" + fields.joined(separator: ",") + "}"
    return try JSONDecoder().decode(PushEnvelope.self, from: Data(json.utf8))
  }

  private func epochMs(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
  }

  private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
