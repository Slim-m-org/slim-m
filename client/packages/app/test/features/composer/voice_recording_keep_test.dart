// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A recorder outlives its composer while it holds a recording or a clip, and
/// only within the account that made it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/providers/session_provider.dart';

import 'voice_recording_test.dart' show Rig;

TokenPair _tokens(String userId, {String access = 'a'}) => TokenPair(
  userId: userId,
  accessToken: access,
  refreshToken: 'r',
  accessExpiresAt: 0,
);

void main() {
  late Rig rig;
  late SessionStore session;
  late ProviderSubscription<VoiceRecordingState> composer;

  bool kept() => rig.container.exists(voiceRecorderProvider('c1'));

  /// Closes the composer and lets an autodispose run.
  Future<void> leave() async {
    composer.close();
    await pumpEventQueue();
  }

  Future<void> recording({bool allowed = true}) async {
    session = SessionStore(tokens: _tokens('u1'));
    rig = Rig(
      allowed: allowed,
      overrides: [sessionProvider.overrideWithValue(session)],
    );
    addTearDown(rig.container.dispose);
    composer = rig.container.listen(voiceRecorderProvider('c1'), (_, _) {});
    await rig.recorder.start();
  }

  test('a recording outlives its composer and stops for a call', () async {
    await recording();
    await rig.advance(const Duration(seconds: 2));
    await leave();
    expect(kept(), isTrue);
    expect(rig.capture.cancelled, isFalse);

    await rig.advance(const Duration(seconds: 2));
    await rig.container.read(callStartYieldsProvider).callStarting();

    expect(rig.state.phase, VoicePhase.stopped);
    expect(rig.state.clip?.duration, const Duration(seconds: 4));
    expect(rig.capture.cancelled, isFalse);
  });

  test('a clip still being finished away from its composer is kept', () async {
    await recording();
    await rig.advance(const Duration(seconds: 3));
    await leave();
    final finish = Completer<void>();
    rig.capture.finishing = finish.future;

    final yielding = rig.container.read(callStartYieldsProvider).callStarting();
    await pumpEventQueue();
    finish.complete();
    await yielding;

    expect(rig.state.phase, VoicePhase.stopped);
    expect(rig.state.clip?.duration, const Duration(seconds: 3));
  });

  test('a clip whose upload failed outlives its composer', () async {
    await recording();
    await rig.advance(const Duration(seconds: 3));
    rig.actions.failures = 1;
    await rig.recorder.send();
    await leave();

    expect(kept(), isTrue);
    expect(rig.state.clip, isNotNull);
    expect(await rig.recorder.send(), isNotNull);
  });

  test('sending a kept clip lets the recorder go', () async {
    await recording();
    await rig.advance(const Duration(seconds: 3));
    await leave();
    await rig.recorder.send();
    await pumpEventQueue();

    expect(rig.actions.uploads, hasLength(1));
    expect(kept(), isFalse);
  });

  test('a recorder holding no audio goes with its composer', () async {
    await recording(allowed: false);
    expect(rig.state.phase, VoicePhase.failed);
    await leave();
    expect(kept(), isFalse);
  });

  test(
    'its account leaving the screen ends the recording, keeping the clip',
    () async {
      await recording();
      await rig.advance(const Duration(seconds: 3));
      await leave();

      rig.container.read(accountActiveProvider.notifier).state = false;
      await pumpEventQueue();

      expect(rig.capture.stopped, isTrue);
      expect(rig.capture.cancelled, isFalse);
      expect(rig.state.phase, VoicePhase.stopped);
      expect(rig.state.stoppedForCall, isFalse);
    },
  );

  test('another account signing in throws a kept recording away', () async {
    for (final next in [_tokens('u2'), null]) {
      await recording();
      await rig.advance(const Duration(seconds: 3));
      await leave();

      session.set(next);
      await pumpEventQueue();

      expect(rig.capture.cancelled, isTrue, reason: '$next');
      expect(kept(), isFalse, reason: '$next');
    }
  });

  test('a token refresh for the same account keeps the recording', () async {
    await recording();
    await rig.advance(const Duration(seconds: 3));
    await leave();

    session.set(_tokens('u1', access: 'b'));
    await pumpEventQueue();

    expect(rig.capture.cancelled, isFalse);
    expect(rig.state.phase, VoicePhase.recording);
  });
}
