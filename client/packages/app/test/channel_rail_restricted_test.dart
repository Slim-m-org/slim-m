// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's `restricted` glyph: a lock in place of the hash or the voice
/// icon when `@everyone` cannot view the channel, and no change at all when
/// the field is absent (a server too old to send it) or explicitly false.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(
  String id,
  String name, {
  String kind = 'text',
  bool? restricted,
}) => Channel(
  id: id,
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  restricted: restricted,
);

Widget _harness(Widget child) => ProviderScope(
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: child),
  ),
);

Future<void> _pumpSections(WidgetTester tester, Channel channel) async {
  await tester.pumpWidget(
    _harness(
      ChannelCategorySections(
        channels: [channel],
        categories: const [],
        selectedId: null,
        onReorder: (_) {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a restricted text channel shows the hash with a lock badge', (
    tester,
  ) async {
    await _pumpSections(tester, _channel('c1', 'staff', restricted: true));

    expect(find.byIcon(AppIcons.restrictedChannel), findsOneWidget);
    expect(find.byIcon(AppIcons.hash), findsOneWidget);
    expect(find.byIcon(AppIcons.voice), findsNothing);
  });

  testWidgets(
    'a restricted voice channel shows the speaker with a lock badge',
    (tester) async {
      await _pumpSections(
        tester,
        _channel('c1', 'staff-voice', kind: 'voice', restricted: true),
      );

      expect(find.byIcon(AppIcons.restrictedChannel), findsOneWidget);
      expect(find.byIcon(AppIcons.voice), findsOneWidget);
      expect(find.byIcon(AppIcons.hash), findsNothing);
    },
  );

  testWidgets('an ordinary text channel keeps its hash and carries no lock', (
    tester,
  ) async {
    await _pumpSections(tester, _channel('c1', 'general', restricted: false));

    expect(find.byIcon(AppIcons.hash), findsOneWidget);
    expect(find.byIcon(AppIcons.restrictedChannel), findsNothing);
  });

  testWidgets(
    'a channel with no restricted field renders exactly as it always has',
    (tester) async {
      await _pumpSections(tester, _channel('c1', 'general'));

      expect(find.byIcon(AppIcons.hash), findsOneWidget);
      expect(find.byIcon(AppIcons.restrictedChannel), findsNothing);
    },
  );
}
