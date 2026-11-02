// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share a dropped call was carrying comes back, or the call says it is gone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_share_resume.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _screen = ScreenShareSource(id: 'screen-2', name: 'Screen 2');
const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: true,
);

class _Session extends FakeSession {
  _Session({super.needsSource, super.sourcePickerUseful});

  List<ScreenShareSource> listed = const [_screen];

  @override
  Future<List<ScreenShareSource>> screenShareSources() async => listed;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async {
    lastDisconnect = null;
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    emitState(VoiceSessionState.connected);
  }
}

const _settle = Duration(milliseconds: 120);

void main() {
  final harness = VoiceHarness();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  Future<(VoiceController, _Session)> sharing({bool restartable = true}) async {
    final session = _Session(
      needsSource: restartable,
      sourcePickerUseful: restartable,
    );
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      autoRejoinDelays: const [Duration(milliseconds: 20)],
    );
    await Future<void>.delayed(_settle);
    await controller.join('channel-1');
    await controller.share.setScreenShare(
      true,
      sourceId: 'screen-2',
      source: _screen,
    );
    session.emitParticipants(const [_me]);
    await Future<void>.delayed(_settle);
    session.shareCalls.clear();
    return (controller, session);
  }

  Future<void> drop(
    _Session session, {
    bool wasSharing = true,
    VoiceDisconnect reason = VoiceDisconnect.connectionLost,
  }) async {
    session.droppedWhileSharing = wasSharing;
    session.emitParticipants(const []);
    session.dropWith(reason);
    await Future<void>.delayed(_settle);
  }

  test('a restartable share starts again on the same screen', () async {
    final (controller, session) = await sharing();
    await drop(session);

    expect(session.shareCalls.map((c) => (c.enabled, c.sourceId)), [
      (true, 'screen-2'),
    ]);
    expect(controller.state.screenSharing, isTrue);
    expect(controller.state.error, isNull);
  });

  test('a share that cannot restart on its own says it ended', () async {
    final (controller, session) = await sharing(restartable: false);
    await drop(session);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, shareEndedByDropNotice);
    expect(controller.state.screenSharing, isFalse);
  });

  test('a share whose screen is gone is never moved to another one', () async {
    final (controller, session) = await sharing();
    session.listed = const [ScreenShareSource(id: 'screen-9', name: 'Other')];
    await drop(session);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, shareEndedByDropNotice);
  });

  test('a call that was not sharing when it dropped says nothing', () async {
    final (controller, session) = await sharing();
    await drop(session, wasSharing: false);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });

  test('hanging up before the call returns forgets the share', () async {
    final (controller, session) = await sharing();
    session.droppedWhileSharing = true;
    session.emitParticipants(const []);
    session.dropWith(VoiceDisconnect.connectionLost);
    await pumpEventQueue();
    await controller.leave();
    await controller.join('channel-1');
    await Future<void>.delayed(_settle);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });

  test('a drop that is not rejoined owes no share to a later join', () async {
    final (controller, session) = await sharing();
    await drop(session, reason: VoiceDisconnect.replacedByOtherDevice);
    await controller.join('channel-1');
    await Future<void>.delayed(_settle);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });

  test('joining another channel forgets the share', () async {
    final (controller, session) = await sharing();
    session.droppedWhileSharing = true;
    session.emitParticipants(const []);
    session.dropWith(VoiceDisconnect.connectionLost);
    await pumpEventQueue();
    await controller.join('channel-2');
    await Future<void>.delayed(_settle);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });
}
