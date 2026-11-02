// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A join that asks for the camera reaches connected first and opens it after.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _OneCamera implements CameraDevices {
  @override
  Future<List<CameraDevice>> list() async =>
      const [CameraDevice(id: 'cam-1', label: 'Webcam')];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Completer<void> gate;
  late List<VoiceSessionState> stateWhenCameraAsked;
  late List<CameraJoinOpen> opens;
  late VoiceSession session;

  VoiceSession build({Duration timeout = const Duration(seconds: 10)}) {
    final built = VoiceSession(
      roomFactory: () => InstantRoom(
        camera: (enabled, options) {
          stateWhenCameraAsked.add(session.state);
          return gate.future;
        },
      ),
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      cameraDevices: _OneCamera(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
      cameraJoinTimeout: timeout,
    );
    built.cameraJoinOpens.listen(opens.add);
    addTearDown(built.dispose);
    return built;
  }

  Future<void> join({bool camera = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        cameraEnabled: camera,
      );

  setUp(() {
    gate = Completer<void>();
    stateWhenCameraAsked = [];
    opens = [];
    session = build();
  });

  test('the call is connected while the camera is still opening', () async {
    await join();
    await pumpEventQueue();

    expect(session.state, VoiceSessionState.connected);
    expect(opens.map((o) => o.pending), [true]);
    expect(stateWhenCameraAsked, [VoiceSessionState.connected]);
  });

  test('the camera settles without a failure once it opens', () async {
    await join();
    gate.complete();
    await pumpEventQueue();

    expect(opens.map((o) => o.pending), [true, false]);
    expect(opens.last.failure, isNull);
  });

  test('a camera that cannot open is reported and the call stays up', () async {
    await join();
    gate.completeError(StateError('no webcam'));
    await pumpEventQueue();

    expect(session.state, VoiceSessionState.connected);
    expect(opens.last.pending, isFalse);
    expect(opens.last.failure, isNotNull);
    expect(session.lastError, isNotNull);
  });

  test('a camera that never answers is reported as timed out', () async {
    session = build(timeout: const Duration(milliseconds: 20));
    await join();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(opens.last.failure, isA<CameraOpenTimedOut>());
    expect(session.state, VoiceSessionState.connected);
  });

  test('a join with the camera off opens nothing', () async {
    await join(camera: false);
    await pumpEventQueue();

    expect(stateWhenCameraAsked, isEmpty);
    expect(opens, isEmpty);
  });

  test('leaving mid-open ends it quietly and drops a late failure', () async {
    await join();
    await session.leave();
    gate.completeError(StateError('late'));
    await pumpEventQueue();

    expect(opens.map((o) => o.pending), [true, false]);
    expect(opens.last.failure, isNull);
    expect(session.lastError, isNull);
  });

  test('a newer join discards the older call camera outcome', () async {
    await join();
    await join(camera: false);
    gate.completeError(StateError('late'));
    await pumpEventQueue();

    expect(opens.map((o) => o.pending), [true, false]);
    expect(opens.last.failure, isNull);
    expect(session.lastError, isNull);
  });

  test('the join-time camera uses the chosen quality options', () async {
    lk.CameraCaptureOptions? seen;
    final custom = VoiceSession(
      roomFactory: () => InstantRoom(camera: (enabled, options) async {
        seen = options;
      }),
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      cameraDevices: _OneCamera(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    )..setCameraQuality(CameraQuality.high);
    addTearDown(custom.dispose);

    await custom.join(url: 'wss://a.invalid', token: 't', cameraEnabled: true);
    await pumpEventQueue();

    expect(seen?.params, CameraQuality.high.params);
  });
}
