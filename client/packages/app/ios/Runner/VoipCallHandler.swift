// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import CallKit
import Foundation
import PushKit

/// The bundled CallKit ringtone, generated deterministically by
/// `assets/audio/generate.py` from `sounds.py`'s `CALLKIT_RINGTONE` and
/// copied into the Runner target's own bundle by `project.pbxproj`'s Audio
/// group - never hand-dropped, so `audio-ci` catches any drift from source.
let callKitRingtoneFileName = "callkit_ringtone.wav"

/// The one rule this file exists to keep.
///
/// Since iOS 13, an app that receives a VoIP push and does not report an
/// incoming call to CallKit before returning from the push handler is
/// terminated, and doing it repeatedly costs the app its VoIP push privileges
/// entirely. That makes it a correctness invariant rather than a nicety: every
/// path out of `handle` has to report, including the ones where the payload is
/// wrong, where the seal will not open, or where CallKit itself errors.
///
/// The tempting shape is to parse the payload, and bail early if it is
/// rubbish. That is exactly the bug: a malformed push is still a push, and
/// bailing is what gets the app killed. So a payload that cannot be understood
/// is reported as a call from an unknown caller and then immediately ended,
/// which is visible for an instant and survivable, instead of silently fatal.
///
/// A call joined from this app's own UI (not an inbound VoIP push) is a
/// separate path: `handle` below only ever runs from
/// `pushRegistry(_:didReceiveIncomingPushWith:...)`, and it is
/// `VoiceCallReporter.swift`'s `OutgoingCallLifecycle`, not this file, that
/// reports one to `CXProvider` on the outgoing side of the API. See that
/// file's doc comment and https://github.com/NC1107/slim-m/issues/212; it
/// still needs a real device to confirm end to end.
protocol CallReporting {
  func reportNewIncomingCall(
    with uuid: UUID,
    update: CXCallUpdate,
    completion: @escaping (Error?) -> Void
  )
  func reportCall(with uuid: UUID, endedAt: Date?, reason: CXCallEndedReason)
}

extension CXProvider: CallReporting {}

/// What CallKit is doing with a call this file reported, told to Dart so the
/// websocket's copy of the same ring is not prompted for a second time.
enum CallKitCallEvent: Equatable {
  case ringing(UUID)
  case answered(UUID)
  case ended(UUID)

  var wire: [String: String] {
    switch self {
    case .ringing(let id): return ["event": "ringing", "id": id.uuidString]
    case .answered(let id): return ["event": "answered", "id": id.uuidString]
    case .ended(let id): return ["event": "ended", "id": id.uuidString]
    }
  }
}

/// Turns a VoIP push payload into a reported CallKit call.
///
/// Deliberately separate from the PushKit delegate wiring so the invariant can
/// be tested: the delegate below is a few lines of glue, and everything worth
/// asserting on happens here against an injected `CallReporting`.
final class VoipCallHandler {
  private let provider: CallReporting
  private var answered = Set<UUID>()

  /// Set after construction so the tests' one-argument initializer still works.
  var onEvent: ((CallKitCallEvent) -> Void)?

  /// Matches the server's ring timeout, past which the ring is over.
  static let ringTimeout: TimeInterval = 30

  init(provider: CallReporting) {
    self.provider = provider
  }

  /// A call the user picked up must outlive the unanswered-ring timeout below.
  func callAnswered(_ id: UUID) {
    answered.insert(id)
    onEvent?(.answered(id))
  }

  /// The user ended or declined the call on the system screen.
  func callEnded(_ id: UUID) {
    answered.remove(id)
    onEvent?(.ended(id))
  }

  /// Dart reports the ring or the in-app call over, so the system call must not linger.
  func endCall(_ id: UUID) {
    answered.remove(id)
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
  }

  /// The caller name shown when the payload does not say who is calling.
  ///
  /// The push envelope is content-free by design, so this is what most calls
  /// will show until the app is foregrounded and can resolve the channel. A
  /// generic string is the honest thing to display rather than a guess.
  static let unknownCaller = "Incoming call"

  /// The one entry point PushKit's delegate uses, so the type check lives where the
  /// invariant is tested. A non-VoIP type is never delivered to this registry, but
  /// completing it keeps PushKit from waiting on a push nobody will report.
  func handlePush(
    of type: PKPushType,
    payload: [AnyHashable: Any],
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    handle(payload: payload, completion: completion)
  }

  /// Handles one VoIP push. `completion` is PushKit's, and is called only
  /// after CallKit has been told about the call.
  func handle(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
    let callId = Self.callId(from: payload)
    let update = CXCallUpdate()
    update.localizedCallerName = payload["caller"] as? String ?? Self.unknownCaller
    update.hasVideo = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false

    // Reported before anything else can throw, return, or dispatch elsewhere.
    provider.reportNewIncomingCall(with: callId, update: update) { [provider, weak self] error in
      if error == nil {
        self?.onEvent?(.ringing(callId))
        // The push is content-free, so no later push can say the caller hung up.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringTimeout) {
          if self?.answered.contains(callId) != true {
            provider.reportCall(with: callId, endedAt: Date(), reason: .unanswered)
            self?.onEvent?(.ended(callId))
          }
        }
      }
      if error != nil {
        // CallKit refused it (a call already up, Do Not Disturb, and so on).
        // Ending it keeps the app's own idea of active calls in step with
        // CallKit's, which is what stops a ghost call being left on screen.
        provider.reportCall(with: callId, endedAt: Date(), reason: .failed)
      }
      completion()
    }
  }

  /// The call's identity, taken from the payload when it carries a usable one
  /// so that a repeated push for the same call updates it rather than stacking
  /// a second call on screen, and freshly generated when it does not.
  static func callId(from payload: [AnyHashable: Any]) -> UUID {
    if let raw = payload["call_id"] as? String, let parsed = UUID(uuidString: raw) {
      return parsed
    }
    return UUID()
  }
}

/// Registers for VoIP pushes and hands them to [VoipCallHandler].
///
/// Kept apart from `AppDelegate` because the delegate already carries the APNs
/// path; these are two different push types with two different failure modes,
/// and mixing them makes it hard to see that the rule above is being kept.
final class VoipPushRegistrar: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
  private let registry: PKPushRegistry
  private let provider: CXProvider
  private let handler: VoipCallHandler

  /// Called with the VoIP token so the Dart side can register it with the
  /// server, alongside the ordinary APNs token.
  var onToken: ((String) -> Void)?

  /// Called as CallKit's view of an incoming call changes, for the Dart side.
  var onCallEvent: ((CallKitCallEvent) -> Void)?

  override init() {
    registry = PKPushRegistry(queue: .main)

    // The localizedName initializer rather than the empty one: this name is
    // what the system call UI and the Recents list show, and neither should
    // say nothing.
    let configuration = CXProviderConfiguration(localizedName: "slim-m")
    configuration.supportsVideo = false
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    // The one provider that reports an incoming call, so the one that rings.
    configuration.ringtoneSound = callKitRingtoneFileName
    provider = CXProvider(configuration: configuration)

    handler = VoipCallHandler(provider: provider)
    super.init()

    handler.onEvent = { [weak self] event in self?.onCallEvent?(event) }
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    provider.setDelegate(self, queue: .main)
  }

  func endCall(_ id: UUID) {
    handler.endCall(id)
  }

  // MARK: PKPushRegistryDelegate

  func pushRegistry(
    _: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    onToken?(hex)
  }

  func pushRegistry(
    _: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    handler.handlePush(of: type, payload: payload.dictionaryPayload, completion: completion)
  }

  // MARK: CXProviderDelegate

  func providerDidReset(_: CXProvider) {
    // Intentionally empty: this app holds no CallKit state to tear down on a provider reset.
  }

  func provider(_: CXProvider, perform action: CXAnswerCallAction) {
    handler.callAnswered(action.callUUID)
    // Fulfilled so CallKit does not show a failed call; Dart is told and joins the room.
    action.fulfill()
  }

  func provider(_: CXProvider, perform action: CXEndCallAction) {
    handler.callEnded(action.callUUID)
    action.fulfill()
  }
}
