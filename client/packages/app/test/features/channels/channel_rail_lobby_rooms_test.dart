// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A lobby's temporary rooms sit one step in under the lobby in the rail
/// (decision 0065), however their positions fall.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart'
    show kRailRowInset;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _voice(
  String id, {
  required int position,
  bool? createsRooms,
  String? lobbyId,
}) => Channel(
  id: id,
  name: id,
  kind: 'voice',
  createdAt: 0,
  position: position,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  createsRooms: createsRooms,
  roomOwnerId: lobbyId == null ? null : 'owner',
  roomLobbyId: lobbyId,
);

Future<void> _pumpRail(WidgetTester tester, List<Channel> channels) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((_) async => http.Response('', 404)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: channels,
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

double _labelLeft(WidgetTester tester, String name) =>
    tester.getTopLeft(find.text(name)).dx;

double _labelTop(WidgetTester tester, String name) =>
    tester.getTopLeft(find.text(name)).dy;

void main() {
  testWidgets('a room is drawn one step in, right under its own lobby', (
    tester,
  ) async {
    await _pumpRail(tester, [
      _voice('dev-lobby', position: 0, createsRooms: true),
      _voice('games-lobby', position: 1, createsRooms: true),
      _voice('games room', position: 2, lobbyId: 'games-lobby'),
      _voice('npc room', position: 3, lobbyId: 'dev-lobby'),
    ]);

    expect(
      _labelLeft(tester, 'npc room') - _labelLeft(tester, 'dev-lobby'),
      kRailRowInset,
    );
    expect(
      _labelLeft(tester, 'games room') - _labelLeft(tester, 'games-lobby'),
      kRailRowInset,
    );
    final tops = [
      for (final name in ['dev-lobby', 'npc room', 'games-lobby', 'games room'])
        _labelTop(tester, name),
    ];
    expect(tops, [...tops]..sort(), reason: 'each room follows its lobby');
  });

  testWidgets('a plain voice channel keeps the lobby\'s indent', (
    tester,
  ) async {
    await _pumpRail(tester, [
      _voice('dev-lobby', position: 0, createsRooms: true),
      _voice('lounge', position: 1),
    ]);

    expect(_labelLeft(tester, 'lounge'), _labelLeft(tester, 'dev-lobby'));
  });
}
