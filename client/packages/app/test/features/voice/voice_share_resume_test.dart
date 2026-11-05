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
  bool listingFails = false;
  int joins = 0;

  @override
  Future<List<ScreenShareSource>> screenShareSources() async {
    if (listingFails) throw StateError('portal gone');
    return listed;
  }

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async {
    joins++;
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

/// Long enough that a drop is still unanswered when the test hangs up or switches channel.
const _neverRejoins = Duration(hours: 1);

/// Polls the real condition rather than guessing how long a loaded box needs.
Future<void> until(bool Function() done, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition never held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await pumpEventQueue(times: 100);
}

void main() {
  final harness = VoiceHarness();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  Future<(VoiceController, _Session)> sharing({
    bool restartable = true,
    Duration rejoinDelay = const Duration(milliseconds: 20),
  }) async {
    final session = _Session(
      needsSource: restartable,
      sourcePickerUseful: restartable,
    );
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      autoRejoinDelays: [rejoinDelay],
    );
    await pumpEventQueue(times: 100);
    await controller.join('channel-1');
    await controller.share.setScreenShare(
      true,
      sourceId: 'screen-2',
      source: _screen,
    );
    session.emitParticipants(const [_me]);
    await until(
      () => controller.state.screenSharing,
      reason: 'the share never started',
    );
    session.shareCalls.clear();
    return (controller, session);
  }

  Future<void> drop(
    _Session session, {
    bool wasSharing = true,
    VoiceDisconnect reason = VoiceDisconnect.connectionLost,
  }) async {
    final joinsBefore = session.joins;
    session.droppedWhileSharing = wasSharing;
    session.emitParticipants(const []);
    session.dropWith(reason);
    if (reason == VoiceDisconnect.connectionLost) {
      await until(
        () => session.joins > joinsBefore,
        reason: 'the call never rejoined',
      );
    }
    await pumpEventQueue(times: 100);
  }

  Future<void> rejoined(_Session session, int joinsBefore) => until(
    () => session.joins > joinsBefore,
    reason: 'the new join never reached the session',
  );

  test('a restartable share starts again on the same screen', () async {
    final (controller, session) = await sharing();
    await drop(session);
    await until(
      () => session.shareCalls.isNotEmpty,
      reason: 'the share never restarted',
    );

    expect(session.shareCalls.map((c) => (c.enabled, c.sourceId)), [
      (true, 'screen-2'),
    ]);
    expect(controller.state.screenSharing, isTrue);
    expect(controller.state.error, isNull);
  });

  test('a share that cannot restart on its own says it ended', () async {
    final (controller, session) = await sharing(restartable: false);
    await drop(session);
    await until(
      () => controller.state.error != null,
      reason: 'the drop was never reported',
    );

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, shareEndedByDropNotice);
    expect(controller.state.screenSharing, isFalse);
  });

  test('a share whose screen is gone is never moved to another one', () async {
    final (controller, session) = await sharing();
    session.listed = const [ScreenShareSource(id: 'screen-9', name: 'Other')];
    await drop(session);
    await until(
      () => controller.state.error != null,
      reason: 'the drop was never reported',
    );

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, shareEndedByDropNotice);
  });

  test('a restart that throws still says the share ended', () async {
    final (controller, session) = await sharing();
    session.listingFails = true;
    await drop(session);
    await until(
      () => controller.state.error != null,
      reason: 'the failed restart was never reported',
    );

    expect(controller.state.error, shareEndedByDropNotice);
    expect(controller.state.screenSharing, isFalse);
  });

  test('a call that was not sharing when it dropped says nothing', () async {
    final (controller, session) = await sharing();
    await drop(session, wasSharing: false);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });

  test('hanging up before the call returns forgets the share', () async {
    final (controller, session) = await sharing(rejoinDelay: _neverRejoins);
    session.droppedWhileSharing = true;
    session.emitParticipants(const []);
    session.dropWith(VoiceDisconnect.connectionLost);
    await pumpEventQueue();
    await controller.leave();
    final joinsBefore = session.joins;
    await controller.join('channel-1');
    await rejoined(session, joinsBefore);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });

  test('a drop that is not rejoined owes no share to a later join', () async {
    final (controller, session) = await sharing();
    await drop(session, reason: VoiceDisconnect.replacedByOtherDevice);
    final joinsBefore = session.joins;
    await controller.join('channel-1');
    await rejoined(session, joinsBefore);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });

  test('joining another channel forgets the share', () async {
    final (controller, session) = await sharing(rejoinDelay: _neverRejoins);
    session.droppedWhileSharing = true;
    session.emitParticipants(const []);
    session.dropWith(VoiceDisconnect.connectionLost);
    await pumpEventQueue();
    final joinsBefore = session.joins;
    await controller.join('channel-2');
    await rejoined(session, joinsBefore);

    expect(session.shareCalls, isEmpty);
    expect(controller.state.error, isNull);
  });
}
