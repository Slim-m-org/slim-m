// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A join_muted voice channel says so on the screen a member joins from and,
/// since the owner asked for it (2026-10-09), on its rail row too.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'voice_controller_harness.dart';

const _id = 'c-stage';

Channel _voice({required bool joinMuted}) => Channel(
  id: _id,
  name: 'stage',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: joinMuted,
  isPersonalSpace: false,
);

Future<void> _pumpRail(WidgetTester tester, Channel channel) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: voiceApi(status: 501),
          );
          ref.onDispose(client.close);
          return client;
        }),
        voiceRosterProvider(_id).overrideWith(
          (ref) => Stream.value(const <api.VoiceRosterParticipant>[]),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: [channel],
            categories: const [],
            selectedId: null,
            onReorder: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpRejoin(WidgetTester tester, Channel channel) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: voiceApi(status: 501),
        );
        ref.onDispose(client.close);
        return client;
      }),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
      channelByIdProvider(_id).overrideWith((ref) => Stream.value(channel)),
      voiceRosterProvider(_id).overrideWith(
        (ref) => Stream.value(const <api.VoiceRosterParticipant>[]),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: VoiceScreen(channelId: _id)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the rail row of a join_muted channel carries the mic-off glyph',
    (tester) async {
      await _pumpRail(tester, _voice(joinMuted: true));

      expect(find.text('stage'), findsOneWidget);
      expect(find.byIcon(AppIcons.micOff), findsOneWidget);
      expect(find.byTooltip('Joins muted'), findsOneWidget);
    },
  );

  testWidgets('the rejoin screen says a join_muted channel joins with the mic '
      'off', (tester) async {
    await _pumpRejoin(tester, _voice(joinMuted: true));

    expect(find.text('Joins with your mic off'), findsOneWidget);
    expect(find.byIcon(AppIcons.micOff), findsOneWidget);
  });

  testWidgets('the rejoin screen is unchanged for an ordinary channel', (
    tester,
  ) async {
    await _pumpRejoin(tester, _voice(joinMuted: false));

    expect(find.text('Voice channel'), findsOneWidget);
    expect(find.text('Joins with your mic off'), findsNothing);
  });
}
