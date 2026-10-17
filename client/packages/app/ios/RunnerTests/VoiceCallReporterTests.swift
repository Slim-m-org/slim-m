// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import CallKit
import XCTest

@testable import Runner

/// A stand-in for `CXCallController` that records what it was asked to
/// request and lets a test decide whether CallKit grants it.
private final class RecordingController: CallRequesting {
  var started: [CXStartCallAction] = []
  var ended: [CXEndCallAction] = []
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
}

/// A stand-in for `CXProvider` that records what it was told to report.
private final class RecordingProvider: OutgoingCallReporting {
  var startedConnecting: [(uuid: UUID, date: Date?)] = []
  var connected: [(uuid: UUID, date: Date?)] = []
  var ended: [(uuid: UUID, reason: CXCallEndedReason)] = []

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
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")

    XCTAssertEqual(controller.started.count, 1)
    XCTAssertEqual(controller.started.first?.callUUID, id)
    XCTAssertEqual(controller.started.first?.handle.value, "Voice call")
    XCTAssertEqual(lifecycle.activeCallId, id)
  }

  func testARepeatCallStartedWhileOneIsActiveIsANoOp() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)

    lifecycle.callStarted(id: UUID(), displayName: "First")
    lifecycle.callStarted(id: UUID(), displayName: "Second")

    XCTAssertEqual(controller.started.count, 1, "one call at a time, per voice_controller.dart")
  }

  func testACallKitRefusalToStartClearsTheActiveCall() {
    let controller = RecordingController()
    controller.startError = NSError(domain: "CXErrorDomain", code: 3)
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)

    lifecycle.callStarted(id: UUID(), displayName: "Voice call")

    XCTAssertNil(lifecycle.activeCallId, "a refused request must not still look active")
  }

  func testHandleStartActionReportsStartedConnectingAndFulfills() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
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
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")
    lifecycle.callConnected()

    XCTAssertEqual(provider.connected.count, 1)
    XCTAssertEqual(provider.connected.first?.uuid, id)
  }

  func testCallConnectedWithNothingActiveReportsNothing() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)

    lifecycle.callConnected()

    XCTAssertTrue(provider.connected.isEmpty)
  }

  func testCallEndedRequestsAnEndActionRatherThanReportingARemoteEnd() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
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
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
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
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
    let id = UUID()

    lifecycle.callStarted(id: id, displayName: "Voice call")
    lifecycle.callEnded()

    XCTAssertEqual(provider.ended.map(\.uuid), [id])
  }

  func testCallEndedWithNothingActiveIsSafe() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)

    lifecycle.callEnded()

    XCTAssertTrue(provider.ended.isEmpty)
  }

  func testHandleEndActionClearsTheActiveCallCallsOnHangUpAndFulfills() {
    let controller = RecordingController()
    let provider = RecordingProvider()
    let lifecycle = OutgoingCallLifecycle(controller: controller, provider: provider)
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
