// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A drop onto a voice channel row is answered after the rail has already
/// re-laid out; the refusal must still reach the rail's failure line.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/rail_participant_drag.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

void main() {
  testWidgets('a refused drop answered after the row is gone still reports', (
    tester,
  ) async {
    final answer = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        mockApiOverride((request) async {
          await answer.future;
          return http.Response('{"error":"nope"}', 403);
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Column(
              children: [
                Draggable<ParticipantDragData>(
                  data: ParticipantDragData(
                    userId: 'bob',
                    name: 'Bob',
                    fromChannelId: 'voice-1',
                  ),
                  feedback: SizedBox(width: 40, height: 20),
                  child: Text('Bob'),
                ),
                SizedBox(height: 80),
                RailMoveDropTarget(
                  key: Key('drop'),
                  channelId: 'voice-2',
                  child: SizedBox(width: 200, height: 60),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final bob = tester.getCenter(find.text('Bob'));
    final target = tester.getCenter(find.byKey(const Key('drop')));

    await tester.dragFrom(bob, target - bob);
    await pumpFrames(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    answer.complete();
    await pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(container.read(railMoveFailureProvider), contains('move Bob'));
  });
}
