// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/channels/<channel>/m/<message>` through the real router: the address a
/// starboard highlight or a pasted link carries must open the channel and ask
/// for the jump, whether the app was already on that channel or not.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_api/api.dart' as api show Channel;
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart' show NoopSyncController;
import 'voice_controller_harness.dart' show FakeSession;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

class _RecordingJump extends MessageJumpController {
  _RecordingJump(super.ref);

  final jumps = <(String channelId, String messageId)>[];

  @override
  Future<void> jumpTo(String channelId, String messageId) async {
    jumps.add((channelId, messageId));
  }
}

class _RecordingVoiceController extends VoiceController {
  _RecordingVoiceController(super.ref) : super(session: FakeSession());

  final joins = <String>[];

  @override
  Future<void> join(String channelId) async {
    joins.add(channelId);
    state = VoiceState(
      state: VoiceSessionState.connected,
      channelId: channelId,
    );
  }
}

Future<({ProviderContainer container, SlimmDatabase db, GoRouter router})>
_pump(
  WidgetTester tester,
  String start, {
  List<Override> extraOverrides = const [],
  Future<void> Function(SlimmDatabase db)? seed,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = SlimmDatabase(NativeDatabase.memory());
  await seed?.call(db);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      databaseProvider.overrideWith((ref) => db),
      messageJumpProvider.overrideWith(_RecordingJump.new),
      ...extraOverrides,
      apiProvider.overrideWith((ref) {
        final client = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((_) async => throw StateError('no network')),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  container
      .read(chosenServerProvider.notifier)
      .restore(Uri.parse('http://localhost:8080'));
  container.read(sessionProvider).set(_tokens);
  final router = container.read(routerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  router.go(start);
  await tester.pump();
  await tester.pump();
  return (container: container, db: db, router: router);
}

Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

_RecordingJump _jump(ProviderContainer c) =>
    c.read(messageJumpProvider.notifier) as _RecordingJump;

void main() {
  test('the message route is the channel path plus a message id', () {
    expect(Routes.message('c1', 'm1'), '/channels/c1/m/m1');
    expect(Routes.channel('c1'), '/channels/c1');
  });

  testWidgets('a cold link asks for the jump to that message', (tester) async {
    final (:container, :db, :router) = await _pump(
      tester,
      Routes.message('c1', 'm1'),
    );

    expect(_jump(container).jumps, [('c1', 'm1')]);
    expect(router.state.matchedLocation, '/channels/c1/m/m1');

    await _teardown(tester, container, db);
  });

  testWidgets('a second link on the open channel jumps again', (tester) async {
    final (:container, :db, :router) = await _pump(
      tester,
      Routes.message('c1', 'm1'),
    );

    router.go(Routes.message('c1', 'm2'));
    await tester.pump();
    await tester.pump();

    expect(_jump(container).jumps, [('c1', 'm1'), ('c1', 'm2')]);

    await _teardown(tester, container, db);
  });

  testWidgets('the plain channel route asks for no jump', (tester) async {
    final (:container, :db, router: _) = await _pump(
      tester,
      Routes.channel('c1'),
    );

    expect(_jump(container).jumps, isEmpty);

    await _teardown(tester, container, db);
  });

  testWidgets('a link into a voice channel opens its chat and does not join', (
    tester,
  ) async {
    late _RecordingVoiceController voice;
    final (:container, :db, router: _) = await _pump(
      tester,
      Routes.message('c1', 'm1'),
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => voice = _RecordingVoiceController(ref),
        ),
      ],
      seed: (db) => MessageStore(db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'lounge',
          kind: 'voice',
          createdAt: 0,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(voice.joins, isEmpty, reason: 'a link is not consent to join');
    expect(find.text('Join muted'), findsOneWidget);

    await _teardown(tester, container, db);
  });
}
