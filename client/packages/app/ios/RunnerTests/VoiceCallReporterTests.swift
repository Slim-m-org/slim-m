// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import AVFoundation
import CallKit
import XCTest

@testable import Runner

/// A stand-in for `CXCallController` that records what it was asked to
/// request and lets a test decide whether CallKit grants it.
private final class RecordingController: CallRequesting {
  var started: [CXStartCallAction] = []
  var ended: [CXEndCallAction] = []
  var muted: [CXSetMutedCallAction] = []
  var startError: Error?
  var endError: Error?

  func requestStart(_ action: CXStartCallAction, completion: @escaping (Error?) -> Void) {
    started.append(action)
    completion(startError)
  }

  func requestEnd(_ action: CXEndCallAction, completion: @escaping (Error?) -> Void) {
    ended.append(action)
    completion(endError)
  }

  func requestMute(_ action: CXSetMutedCallAction, completion: @escaping (Error?) -> Void) {
    muted.append(action)
    completion(nil)
  }
}

/// A stand-in for `CXProvider` that records what it was told to report.
private final class RecordingProvider: OutgoingCallReporting {
  var startedConnecting: [(uuid: UUID, date: Date?)] = []
  var connected: [(uuid: UUID, date: Date?)] = []
  var ended: [(uuid: UUID, reason: CXCallEndedReason)] = []
  var updated: [(uuid: UUID, update: CXCallUpdate)] = []

  func reportCall(with uuid: UUID, updated update: CXCallUpdate) {
    updated.append((uuid, update))
  }

  func reportOutgoingCall(with uuid: UUID, startedConnectingAt date: Date?) {
    startedConnecting.append((uuid, date))
  }

  func reportOutgoingCall(with uuid: UUID, connectedAt date: Date?) {
    connected.append((uuid, date))
  }

  func reportCall(with uuid: UUID, endedAt _: Date?, reason: CXCallEndedReason) {
    ended.append((uuid, reason))
  }
}

/// Stands in for a CallKit-delivered action. A test cannot use a real one:
/// `fulfill()` is a no-op on an action no `CXTransaction` ever carried, so
/// `isComplete` would stay false however correct the code is.
private final class RecordingMuteAction: MuteActionFulfilling {
  let callUUID: UUID
  let isMuted: Bool
  private(set) var fulfilled = 0

  init(callUUID: UUID, isMuted: Bool) {
    self.callUUID = callUUID
    self.isMuted = isMuted
  }

  func fulfill() { fulfilled += 1 }
}

private final class RecordingAction: CallActionFulfilling {
  let callUUID: UUID
  private(set) var fulfilled = 0

  init(callUUID: UUID) { self.callUUID = callUUID }

  func fulfill() { fulfilled += 1 }
}

/// A UI-joined call must reach CallKit through the outgoing side of its API,
/// since there is no incoming-style "report a new outgoing call" entry
/// point: it has to be requested, granted, and only then reported.
final class OutgoingCallLifecycleTests: XCTestCase {
  func testCallStartedRequestsAStartActionForTheGivenId() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")

    XCTAssertEqual(controller.started.count, 1)
    XCTAssertEqual(controller.started.first?.callUUID, id)
    XCTAssertEqual(controller.started.first?.handle.value, "Voice call")
    XCTAssertEqual(lifecycle.activeCallId, id)
  }

  func testARepeatCallStartedForTheActiveCallIsANoOp() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "First")
    lifecycle.callStarted(id: id, displayName: "Second")

    XCTAssertEqual(controller.started.count, 1, "CallKit already tracks this call")
  }

  func testACallStartedForAnotherCallReplacesTheActiveOne() {
    let controller = RecordingController()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: RecordingProvider(, onMain: { $0() }))
    let first = UUID()
    let second = UUID()

    lifecycle.callStarted(id: first, displayName: "First")
    lifecycle.callStarted(id: second, displayName: "Second")

    XCTAssertEqual(controller.ended.map(\.callUUID), [first])
    XCTAssertEqual(controller.started.map(\.callUUID), [first, second])
    XCTAssertEqual(lifecycle.activeCallId, second)
  }

  func testALateEndForAReplacedCallIsIgnored() {
    let controller = RecordingController()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: RecordingProvider(, onMain: { $0() }))
    let first = UUID()
    let second = UUID()
    lifecycle.callStarted(id: first, displayName: "First")
    lifecycle.callStarted(id: second, displayName: "Second")

    lifecycle.callEnded(callId: first)

    XCTAssertEqual(lifecycle.activeCallId, second)
    XCTAssertEqual(controller.ended.map(\.callUUID), [first], "only the replacement's own end request")
  }

  func testACallKitRefusalToStartClearsTheActiveCall() {
    let controller = RecordingController()
    controller.startError = NSError(domain: "CXErrorDomain", code: 3)
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })

    lifecycle.callStarted(id: UUID(), displayName: "Voice call")

    XCTAssertNil(lifecycle.activeCallId, "a refused request must not still look active")
  }

  func testACallKitRefusalToStartIsReportedWithItsCode() {
    let controller = RecordingController()
    controller.startError = NSError(domain: "CXErrorDomain", code: 6)
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: RecordingProvider(, onMain: { $0() }))
    var events: [[String: Any]] = []
    lifecycle.onEvent = { events.append($0) }

    lifecycle.callStarted(id: UUID(), displayName: "Voice call")

    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["step"] as? String, "start")
    XCTAssertEqual(events.first?["result"] as? String, "failed")
    XCTAssertEqual(events.first?["code"] as? Int, 6)
  }

  func testAStartSkippedForACallStillReportedIsReported() {
    let lifecycle = OutgoingCallLifecycle(controller: RecordingController(, onMain: { $0() }), provider: RecordingProvider())
    var results: [String] = []
    lifecycle.onEvent = { results.append($0["result"] as? String ?? "") }

    let id = UUID()
    lifecycle.callStarted(id: id, displayName: "First")
    lifecycle.callStarted(id: id, displayName: "Second")

    XCTAssertEqual(results, ["ok", "skipped"])
  }

  func testHandleStartActionReportsStartedConnectingAndFulfills() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()
    let action = RecordingAction(callUUID: id)

    lifecycle.handleStartAction(action)

    XCTAssertEqual(provider.startedConnecting.count, 1)
    XCTAssertEqual(provider.startedConnecting.first?.uuid, id)
    XCTAssertEqual(
      action.fulfilled, 1,
      "an unfulfilled start action is timed out by CallKit and the call never starts")
  }

  func testCallConnectedReportsTheActiveCallConnected() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")
    lifecycle.callConnected()

    XCTAssertEqual(provider.connected.count, 1)
    XCTAssertEqual(provider.connected.first?.uuid, id)
  }

  func testCallConnectedWithNothingActiveReportsNothing() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })

    lifecycle.callConnected()

    XCTAssertTrue(provider.connected.isEmpty)
  }

  func testCallEndedRequestsAnEndActionRatherThanReportingARemoteEnd() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")
    lifecycle.callEnded()

    XCTAssertEqual(controller.ended.map(\.callUUID), [id])
    XCTAssertTrue(provider.ended.isEmpty, "a local hangup is not a remote end")
    XCTAssertNil(lifecycle.activeCallId)
  }

  func testTheEndActionForALocalHangupIsFulfilledWithoutEchoingToDart() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()
    lifecycle.callStarted(id: id, displayName: "Voice call")
    var hungUp = false
    lifecycle.onHangUp = { hungUp = true }

    lifecycle.callEnded()
    let action = RecordingAction(callUUID: id)
    lifecycle.handleEndAction(action)

    XCTAssertFalse(hungUp, "Dart already left; telling it again would be an echo")
    XCTAssertEqual(action.fulfilled, 1)
  }

  func testARefusedEndRequestStillReportsTheCallEnded() {
    let controller = RecordingController()
    controller.endError = NSError(domain: "CXErrorDomainRequestTransaction", code: 1)
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")
    lifecycle.callEnded()

    XCTAssertEqual(provider.ended.map(\.uuid), [id])
  }

  func testCallEndedWithNothingActiveIsSafe() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })

    lifecycle.callEnded()

    XCTAssertTrue(provider.ended.isEmpty)
  }

  func testHandleEndActionClearsTheActiveCallCallsOnHangUpAndFulfills() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    let id = UUID()
    lifecycle.callStarted(id: id, displayName: "Voice call")

    var hungUp = false
    lifecycle.onHangUp = { hungUp = true }
    let action = RecordingAction(callUUID: id)
    lifecycle.handleEndAction(action)

    XCTAssertTrue(hungUp, "the system call UI ending the call must tell Dart to leave the room")
    XCTAssertNil(lifecycle.activeCallId)
    XCTAssertEqual(action.fulfilled, 1)
  }
}

/// One provider and one call per room, plus the system's mute, hold and reset.
final class OutgoingCallLifecycleSystemTests: XCTestCase {
  private func make(answered: UUID? = nil) -> (OutgoingCallLifecycle, RecordingController, RecordingProvider) {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider, onMain: { $0() })
    lifecycle.answeredCallId = { answered }
    return (lifecycle, controller, provider)
  }

  func testAJoinAfterAnAnsweredRingAdoptsTheAnsweredCall() {
    let answered = UUID()
    let (lifecycle, controller, provider) = make(answered: answered)

    lifecycle.callStarted(id: UUID(), displayName: "Voice call")

    XCTAssertTrue(controller.started.isEmpty, "a second call would sit beside the answered one")
    XCTAssertEqual(lifecycle.activeCallId, answered)
    XCTAssertTrue(lifecycle.isAdopted(answered))
    lifecycle.callConnected()
    XCTAssertTrue(provider.connected.isEmpty, "an answered call is already connected to CallKit")
  }

  func testEndingAnAdoptedCallEndsTheAnsweredCall() {
    let answered = UUID()
    let channel = UUID()
    let (lifecycle, controller, _) = make(answered: answered)
    lifecycle.callStarted(id: channel, displayName: "Voice call")

    lifecycle.callEnded(callId: channel)

    XCTAssertEqual(controller.ended.map(\.callUUID), [answered])
  }

  func testARepeatStartForTheAdoptedRoomIsSkipped() {
    let channel = UUID()
    let (lifecycle, controller, _) = make(answered: UUID())
    lifecycle.callStarted(id: channel, displayName: "Voice call")
    lifecycle.callStarted(id: channel, displayName: "Voice call")

    XCTAssertTrue(controller.ended.isEmpty)
  }

  func testAStartDeclaresHoldingAndGroupingUnsupported() {
    let (lifecycle, _, provider) = make()
    let id = UUID()

    lifecycle.handleStartAction(RecordingAction(callUUID: id))

    XCTAssertEqual(provider.updated.first?.uuid, id)
    XCTAssertEqual(provider.updated.first?.update.supportsHolding, false)
    XCTAssertEqual(provider.updated.first?.update.supportsGrouping, false)
    XCTAssertEqual(provider.updated.first?.update.supportsDTMF, false)
  }

  func testASystemMuteReachesDartAndIsFulfilled() {
    let (lifecycle, _, _) = make()
    lifecycle.callStarted(id: UUID(), displayName: "Voice call")
    var requests: [Bool] = []
    lifecycle.onMuteRequest = { requests.append($0) }
    let action = RecordingMuteAction(callUUID: lifecycle.activeCallId!, isMuted: true)

    lifecycle.handleMuteAction(action)

    XCTAssertEqual(requests, [true])
    XCTAssertEqual(action.fulfilled, 1)
  }

  func testAMuteTheAppAskedForIsNotSentBackToDart() {
    let (lifecycle, controller, _) = make()
    lifecycle.callStarted(id: UUID(), displayName: "Voice call")
    var requests: [Bool] = []
    lifecycle.onMuteRequest = { requests.append($0) }

    lifecycle.muteChanged(true)
    lifecycle.handleMuteAction(RecordingMuteAction(callUUID: lifecycle.activeCallId!, isMuted: true))

    XCTAssertEqual(controller.muted.map(\.isMuted), [true])
    XCTAssertTrue(requests.isEmpty)
  }

  func testAMuteWithNoCallRequestsNothing() {
    let (lifecycle, controller, _) = make()
    lifecycle.muteChanged(true)
    XCTAssertTrue(controller.muted.isEmpty)
  }

  func testAProviderResetLeavesTheRoom() {
    let (lifecycle, _, _) = make()
    lifecycle.callStarted(id: UUID(), displayName: "Voice call")
    var hungUp = 0
    lifecycle.onHangUp = { hungUp += 1 }

    lifecycle.reset()

    XCTAssertEqual(hungUp, 1, "CallKit forgot the call, so the room must not stay joined")
    XCTAssertNil(lifecycle.activeCallId)
  }

  func testAProviderResetWithNoCallLeavesNothing() {
    let (lifecycle, _, _) = make()
    var hungUp = 0
    lifecycle.onHangUp = { hungUp += 1 }
    lifecycle.reset()
    XCTAssertEqual(hungUp, 0)
  }

  func testACompletionOffTheMainQueueIsHoppedBeforeItTouchesState() {
    let controller = RecordingController()
    controller.startError = NSError(domain: "CXErrorDomain", code: 3)
    var hopped: [() -> Void] = []
    let lifecycle = OutgoingCallLifecycle(
      controller: controller, provider: RecordingProvider(), onMain: { hopped.append($0) })

    lifecycle.callStarted(id: UUID(), displayName: "Voice call")

    XCTAssertNotNil(lifecycle.activeCallId, "nothing may change before the hop to main runs")
    hopped.forEach { $0() }
    XCTAssertNil(lifecycle.activeCallId)
  }
}

private final class RecordingGate: CallAudioGating {
  var log: [String] = []
  func setManualAudio(_ on: Bool) { log.append("manual \(on)") }
  func setAudioEnabled(_ on: Bool) { log.append("enabled \(on)") }
  func sessionActivated(_ session: AVAudioSession) { log.append("activated") }
  func sessionDeactivated(_ session: AVAudioSession) { log.append("deactivated") }
}

/// The audio unit waits for CallKit's activation, and WebRTC manages the session alone with no call.
final class CallAudioHandOffTests: XCTestCase {
  private func make() -> (CallAudioHandOff, RecordingGate, () -> Void) {
    let gate = RecordingGate()
    var timers: [DispatchWorkItem] = []
    let handOff = CallAudioHandOff(gate: gate, schedule: { _, work in timers.append(work) })
    return (handOff, gate, { timers.filter { !$0.isCancelled }.forEach { $0.perform() } })
  }

  func testAudioIsHeldBackUntilCallKitActivatesTheSession() {
    let (handOff, gate, _) = make()
    handOff.begin(UUID())
    XCTAssertEqual(gate.log, ["manual true", "enabled false"])

    handOff.didActivate(AVAudioSession.sharedInstance())
    XCTAssertEqual(gate.log.suffix(2), ["activated", "enabled true"])
  }

  func testTheLastCallEndingHandsTheSessionBackToWebRTC() {
    let (handOff, gate, _) = make()
    let id = UUID()
    handOff.begin(id)
    gate.log = []

    handOff.end(id)

    XCTAssertEqual(gate.log, ["enabled true", "manual false"])
  }

  func testAnotherCallStillUpKeepsTheGate() {
    let (handOff, gate, _) = make()
    let first = UUID()
    handOff.begin(first)
    handOff.begin(UUID())
    gate.log = []

    handOff.end(first)

    XCTAssertTrue(gate.log.isEmpty)
  }

  func testAMissingActivationDoesNotLeaveTheCallSilent() {
    let (handOff, gate, fire) = make()
    handOff.begin(UUID())
    gate.log = []

    fire()

    XCTAssertEqual(gate.log, ["enabled true"])
  }

  func testAnActivationCancelsTheFallback() {
    let (handOff, gate, fire) = make()
    handOff.begin(UUID())
    handOff.didActivate(AVAudioSession.sharedInstance())
    gate.log = []

    fire()

    XCTAssertTrue(gate.log.isEmpty)
  }

  func testADeactivationHoldsAudioAgainWhileACallIsUp() {
    let (handOff, gate, _) = make()
    handOff.begin(UUID())
    handOff.didActivate(AVAudioSession.sharedInstance())
    gate.log = []

    handOff.didDeactivate(AVAudioSession.sharedInstance())

    XCTAssertEqual(gate.log, ["enabled false", "deactivated"])
  }
}

/// CallKit's own activation and deactivation of the session reach the call
/// report with the session as it then is, so a report can show the hand-off.
final class AudioSessionObserverTests: XCTestCase {
  func testACallKitHandOffCarriesItsDirectionAndTheSession() {
    let activated = AudioSessionObserver.callKitHandOff(active: true)
    let deactivated = AudioSessionObserver.callKitHandOff(active: false)

    XCTAssertEqual(activated["kind"] as? String, "callKitAudio")
    XCTAssertEqual(activated["active"] as? Bool, true)
    XCTAssertEqual(deactivated["active"] as? Bool, false)
    XCTAssertNotNil(activated["category"] as? String)
    XCTAssertNotNil(activated["outputs"] as? [String])
  }
}
