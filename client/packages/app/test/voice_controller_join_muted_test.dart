// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Joining a join_muted channel opens the mic off for that call only: the
/// member's own sticky mic preference must come out of it unchanged.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_data/data.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  Future<(FakeSession, VoiceController)> setUpCall() async {
    final store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
    addTearDown(store.db.close);
    await store.upsertChannels([
      const api.Channel(
        id: 'stage',
        name: 'stage',
        kind: 'voice',
        createdAt: 0,
        joinMuted: true,
      ),
      const api.Channel(
        id: 'lounge',
        name: 'lounge',
        kind: 'voice',
        createdAt: 0,
      ),
    ]);
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      extraOverrides: [storeProvider.overrideWith((ref) async => store)],
    );
    await harness.container.read(storeProvider.future);
    return (session, controller);
  }

  test('a previously unmuted member joins a join_muted channel muted, '
      'then keeps the preference for the next ordinary channel', () async {
    final (session, controller) = await setUpCall();
    expect(controller.state.microphoneEnabled, isTrue);

    await controller.join('stage');

    expect(session.askedForMicrophoneOnJoin, isFalse);
    expect(controller.state.microphoneEnabled, isFalse);
    expect(controller.state.joinedMuted, isTrue);

    await controller.toggleMicrophone();
    expect(controller.state.joinedMuted, isFalse);
    await controller.toggleMicrophone();

    await controller.leave();
    expect(
      controller.state.microphoneEnabled,
      isTrue,
      reason: 'leaving a join_muted call must not overwrite the preference',
    );

    await controller.join('lounge');
    expect(session.askedForMicrophoneOnJoin, isTrue);
  });

  test('switching from a join_muted channel straight to an ordinary one '
      'opens the mic again', () async {
    final (session, controller) = await setUpCall();

    await controller.join('stage');
    await controller.join('lounge');

    expect(session.askedForMicrophoneOnJoin, isTrue);
    expect(controller.state.microphoneEnabled, isTrue);
    expect(controller.state.joinedMuted, isFalse);
  });

  test('a member who was already muted stays muted everywhere', () async {
    final (session, controller) = await setUpCall();
    await controller.toggleMicrophone();
    expect(controller.state.microphoneEnabled, isFalse);

    await controller.join('stage');
    await controller.leave();
    await controller.join('lounge');

    expect(session.askedForMicrophoneOnJoin, isFalse);
  });
}
