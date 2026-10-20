// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message arriving in one channel rebuilds nothing in the rail: not the
/// section, not any row, and not the keeper holding the recency loaded.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_latest_message_at.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/providers/live_events.dart';
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

Channel _channel(String id) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

api.Message _message(String channelId, int seq) => api.Message(
  id: '$channelId-m$seq',
  channelId: channelId,
  authorId: 'u',
  authorDisplayName: 'U',
  seq: seq,
  content: 'hi',
  createdAt: seq * 1000,
  editedAt: null,
);

void main() {
  testWidgets('a new message in one channel rebuilds no rail widget', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    final channels = [_channel('c1'), _channel('c2')];
    final container = ProviderContainer(
      overrides: [
        storeProvider.overrideWith((ref) async => store),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((_) async => http.Response('', 404)),
      ],
    );
    // Drift answers in real time and riverpod resolves on the fake clock, so each needs its turn.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
    }

    await tester.runAsync(() async {
      await store.upsertChannels([
        for (final c in channels)
          api.Channel(id: c.id, name: c.name, kind: 'text', createdAt: 0),
      ]);
      for (final c in channels) {
        await store.applyMessage(_message(c.id, 1));
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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
    await settle();
    expect(
      container.read(channelLatestMessageAtProvider('c1')).valueOrNull,
      1000,
      reason: 'the keeper loaded the newest message time',
    );

    final rebuilt = <String>[];
    debugOnRebuildDirtyWidget = (element, _) {
      final widget = element.widget;
      if (widget is KeepsLatestMessageLoaded) {
        rebuilt.add('keeper ${widget.channelId}');
      } else if (widget is ChannelCategorySections) {
        rebuilt.add('section');
      } else if (widget is ManagedChannelRow) {
        rebuilt.add('row ${widget.channel.id}');
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await tester.runAsync(() => store.applyMessage(_message('c1', 2)));
    await settle();

    expect(
      container.read(channelLatestMessageAtProvider('c1')).valueOrNull,
      2000,
      reason: 'the new message reached the keeper at all',
    );
    expect(rebuilt, isEmpty);

    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  });
}
