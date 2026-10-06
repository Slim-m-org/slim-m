// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import CallKit
import Flutter
import Foundation

/// What [OutgoingCallLifecycle] tells CallKit about a call this app decided
/// to start, as distinct from [CallReporting] in `VoipCallHandler.swift`,
/// which is what an inbound VoIP push uses.
protocol OutgoingCallReporting {
  func reportOutgoingCall(with uuid: UUID, startedConnectingAt date: Date?)
  func reportOutgoingCall(with uuid: UUID, connectedAt date: Date?)
  func reportCall(with uuid: UUID, endedAt date: Date?, reason: CXCallEndedReason)
}

extension CXProvider: OutgoingCallReporting {}

/// Requests CallKit start or end a call. The seam a test drives instead of a
/// real `CXCallController`, which talks to the CallKit daemon and only runs
/// on a device or simulator, never in a plain XCTest process.
protocol CallRequesting {
  func requestStart(_ action: CXStartCallAction, completion: @escaping (Error?) -> Void)
  func requestEnd(_ action: CXEndCallAction, completion: @escaping (Error?) -> Void)
}

extension CXCallController: CallRequesting {
  func requestStart(_ action: CXStartCallAction, completion: @escaping (Error?) -> Void) {
    request(CXTransaction(action: action), completion: completion)
  }

  func requestEnd(_ action: CXEndCallAction, completion: @escaping (Error?) -> Void) {
    request(CXTransaction(action: action), completion: completion)
  }
}

/// A CallKit action this class has to fulfil, as a seam rather than the
/// concrete `CXStartCallAction`/`CXEndCallAction`.
///
/// The seam exists because `fulfill()` does nothing to an action a test
/// constructed itself: an action only becomes complete when CallKit
/// delivered it inside a real `CXTransaction`, so `isComplete` stays false
/// off-device no matter what the code does. Asserting on it therefore tests
/// nothing, while failing to fulfil at all is a real bug - CallKit times the
/// action out and the call never starts. Recording the call through this
/// protocol is what makes the difference observable.
protocol CallActionFulfilling: AnyObject {
  var callUUID: UUID { get }
  func fulfill()
}

extension CXCallAction: CallActionFulfilling {}

/// Reports a call this app's own UI joined - never an inbound VoIP push - to
/// CallKit, so it gets the same background execution grant an incoming call
/// already gets. See `VoipCallHandler.swift`'s doc comment and
/// https://github.com/NC1107/slim-m/issues/212.
///
/// CallKit has no "report a new outgoing call" entry point the way
/// `reportNewIncomingCall` exists for an inbound one: an outgoing call has to
/// be requested with a `CXStartCallAction` first, so [callStarted] asks and
/// [handleStartAction] (run from the provider delegate once CallKit grants
/// it) is where `reportOutgoingCall(startedConnectingAt:)` actually happens -
/// nothing may report anything before that point, since CallKit has no call
/// object yet to attach it to.
final class OutgoingCallLifecycle {
  private let controller: CallRequesting
  private let provider: OutgoingCallReporting

  init(controller: CallRequesting, provider: OutgoingCallReporting) {
    self.controller = controller
    self.provider = provider
  }

  private(set) var activeCallId: UUID?

  /// Runs when the system call UI ends this call (Dynamic Island, the lock
  /// screen), rather than this app's own hangup. Wired to tell the Dart side
  /// to actually leave the room: fulfilling the action alone would only end
  /// CallKit's own idea of the call and leave the room connected underneath.
  var onHangUp: (() -> Void)?

  /// Asks CallKit to start reporting [id] as an outgoing call. A second call
  /// while one is already active is a no-op: this app holds one call at a
  /// time (`voice_controller.dart`'s own doc comment says so), so a repeat
  /// request here would ask CallKit to track a call it already tracks.
  func callStarted(id: UUID, displayName: String) {
    guard activeCallId == nil else { return }
    activeCallId = id
    let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: displayName))
    action.isVideo = false
    controller.requestStart(action) { [weak self] error in
      // CallKit refused the request (Do Not Disturb, another call already
      // up); nothing was reported, so nothing should still look active.
      if error != nil, self?.activeCallId == id {
        self?.activeCallId = nil
      }
    }
  }

  /// CallKit grants the request from [callStarted] here.
  func handleStartAction(_ action: CallActionFulfilling) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  /// The room actually connected.
  func callConnected() {
    guard let id = activeCallId else { return }
    provider.reportOutgoingCall(with: id, connectedAt: Date())
  }

  /// This side ended the call. Safe to call with nothing active.
  func callEnded() {
    guard let id = activeCallId else { return }
    activeCallId = nil
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
  }

  /// The system call UI asked to end the call.
  func handleEndAction(_ action: CallActionFulfilling) {
    activeCallId = nil
    onHangUp?()
    action.fulfill()
  }
}

/// Owns the `CXProvider` for calls this app's own UI joins, and bridges it to
/// the Dart-side `top.npcserver.slimm/call_lifecycle` channel (see
/// `packages/platform/lib/src/call_lifecycle_channel.dart`).
///
/// A separate `CXProvider` from `VoipPushRegistrar`'s: that one exists for an
/// inbound VoIP push, so the two never report the same call. Consolidating
/// onto one shared provider needs a device to confirm the ringtone and audio
/// session hand-off, so it is left apart.
///
/// `provider(_:didActivate:)`/`didDeactivate:` are deliberately not
/// implemented: wiring them to the `AVAudioSession` livekit_client and
/// flutter_webrtc use for the call would need importing WebRTC's own audio
/// session type directly into this target and setting its manual-audio mode
/// globally, which affects every call this app makes, CallKit-reported or
/// not, and cannot be verified without a real device. Left for a follow-up
/// on https://github.com/NC1107/slim-m/issues/212 rather than guessed at
/// here; the default (no manual audio session hand-off) is what this app
/// already runs today.
final class VoiceCallChannel: NSObject, CXProviderDelegate {
  static let name = "top.npcserver.slimm/call_lifecycle"

  private let lifecycle: OutgoingCallLifecycle
  private var flutterChannel: FlutterMethodChannel?

  init(provider: CXProvider = VoiceCallChannel.makeProvider()) {
    lifecycle = OutgoingCallLifecycle(controller: CXCallController(), provider: provider)
    super.init()
    provider.setDelegate(self, queue: .main)
    lifecycle.onHangUp = { [weak self] in
      self?.flutterChannel?.invokeMethod("endCall", arguments: nil)
    }
  }

  /// `ringtoneSound` is set here too though never actually played - this
  /// provider only ever reports an outgoing call, and CallKit's ringtone is
  /// for an incoming one - so the two configurations stay in sync in case
  /// the providers are ever consolidated, per this file's own doc comment.
  private static func makeProvider() -> CXProvider {
    let configuration = CXProviderConfiguration(localizedName: "slim-m")
    configuration.supportsVideo = false
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.ringtoneSound = callKitRingtoneFileName
    return CXProvider(configuration: configuration)
  }

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    flutterChannel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "callStarted":
      handleCallStarted(call, result: result)
    case "callConnected":
      lifecycle.callConnected()
      result(nil)
    case "callEnded":
      lifecycle.callEnded()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleCallStarted(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let idString = args["callId"] as? String,
      let id = UUID(uuidString: idString),
      let displayName = args["displayName"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "callId/displayName missing or invalid", details: nil))
      return
    }
    lifecycle.callStarted(id: id, displayName: displayName)
    result(nil)
  }

  // MARK: CXProviderDelegate

  func providerDidReset(_: CXProvider) {
    // Intentionally empty: this app holds no CallKit state to tear down on a provider reset.
  }

  func provider(_: CXProvider, perform action: CXStartCallAction) {
    lifecycle.handleStartAction(action)
  }

  func provider(_: CXProvider, perform action: CXEndCallAction) {
    lifecycle.handleEndAction(action)
  }
}
