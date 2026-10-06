// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The room's watch position on the call surface: read from REST alone,
/// advanced by the clock while playing, corrected by a tick, and gone when the
/// bot stops ticking. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/watch_room.dart';
import 'package:slimm_app/src/widgets/watch_session_bar.dart';
import 'package:slimm_design_system/design_system.dart';

final _start = DateTime.utc(2026, 9, 30, 20);

Map<String, Object?> _session({bool playing = true, int position = 5025000}) =>
    {
      'channel_id': 'call-1',
      'bot_user_id': 'jelly',
      'item_id': 'item-1',
      'title': 'A Film',
      'duration_ms': 7200000,
      'playing': playing,
      'position_ms': position,
      'sampled_at_ms': 10000,
      'epoch': 1,
      'controller_user_id': null,
      'ttl_ms': 30000,
      'server_time_ms': 12000,
    };

class _Rig {
  _Rig(this.events, this.container);

  final StreamController<api.ServerEvent> events;
  final ProviderContainer container;
  int reads = 0;
}

api.WatchTick _tick({
  int epoch = 1,
  int sampledAtMs = 12000,
  int positionMs = 6000000,
  bool playing = false,
  bool ended = false,
  String itemId = 'item-1',
  String bot = 'jelly',
}) => api.WatchTick(
  channelId: 'call-1',
  botUserId: bot,
  ended: ended,
  itemId: itemId,
  playing: playing,
  positionMs: positionMs,
  sampledAtMs: sampledAtMs,
  epoch: epoch,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<_Rig> _pump(
  WidgetTester tester, {
  required Map<String, Object?>? session,
  double width = 360,
  Future<http.Response> Function(int read)? respond,
}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  var clock = _start;
  late final _Rig rig;
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      watchClockProvider.overrideWithValue(() => clock),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'u1',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 4102444800000,
            ),
          ),
          httpClient: MockClient((http.Request request) async {
            rig.reads++;
            if (respond != null) return respond(rig.reads);
            return http.Response(
              jsonEncode(session ?? {'error': 'no watch session'}),
              session == null ? 404 : 200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  rig = _Rig(events, container);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: const WatchSessionBar(channelId: 'call-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  _advance = (d) => clock = clock.add(d);
  return rig;
}

late DateTime Function(Duration) _advance;

void main() {
  testWidgets('a joiner reads the room position from REST alone', (
    tester,
  ) async {
    await _pump(tester, session: _session());
    expect(find.text('A Film'), findsOneWidget);
    // 5025s sampled 2s before the read, playing: 1:23:47 of 2:00:00.
    expect(find.text('1:23:47 / 2:00:00'), findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Watching A Film, playing')),
      findsOneWidget,
    );
  });

  testWidgets('a paused room holds its position and says so', (tester) async {
    await _pump(tester, session: _session(playing: false));
    expect(find.text('1:23:45 / 2:00:00'), findsOneWidget);
    expect(find.byIcon(AppIcons.pause), findsOneWidget);
  });

  testWidgets('nothing is drawn when nothing is playing', (tester) async {
    await _pump(tester, session: null);
    expect(find.text('A Film'), findsNothing);
    expect(find.byType(Container), findsNothing);
  });

  testWidgets('a tick moves the readout and a pause freezes it', (
    tester,
  ) async {
    final rig = await _pump(tester, session: _session());
    rig.events.add(_tick());
    await _settle(tester);
    expect(find.text('1:40:00 / 2:00:00'), findsOneWidget);
    expect(find.byIcon(AppIcons.pause), findsOneWidget);
    expect(rig.reads, 1, reason: 'same epoch needs no re-read');
  });

  testWidgets('a new epoch re-reads the session for the new title', (
    tester,
  ) async {
    final rig = await _pump(tester, session: _session());
    rig.events.add(_tick(epoch: 2, positionMs: 1000, playing: true));
    await _settle(tester);
    expect(rig.reads, 2);
  });

  testWidgets('a tick from another bot or item re-reads the session', (
    tester,
  ) async {
    final rig = await _pump(tester, session: _session());
    rig.events.add(_tick(bot: 'other'));
    await _settle(tester);
    expect(rig.reads, 2);
    rig.events.add(_tick(itemId: 'item-2'));
    await _settle(tester);
    expect(rig.reads, 3);
  });

  testWidgets('a tick older than the sample, or of a lower epoch, is dropped', (
    tester,
  ) async {
    final rig = await _pump(tester, session: _session(position: 5025000));
    rig.events.add(_tick(sampledAtMs: 9000, positionMs: 6000000));
    rig.events.add(_tick(epoch: 0, sampledAtMs: 13000, positionMs: 6000000));
    await _settle(tester);
    expect(find.text('1:23:47 / 2:00:00'), findsOneWidget);
    expect(rig.reads, 1, reason: 'a lower epoch is not a cue to re-read');
  });

  testWidgets('a read that finishes after a newer tick does not undo it', (
    tester,
  ) async {
    final late = Completer<http.Response>();
    final rig = await _pump(
      tester,
      session: _session(),
      respond: (read) => read == 1
          ? Future.value(
              http.Response(
                jsonEncode(_session()),
                200,
                headers: {'content-type': 'application/json'},
              ),
            )
          : late.future,
    );
    rig.events.add(_tick(bot: 'other'));
    await _settle(tester);
    rig.events.add(_tick(sampledAtMs: 13000, positionMs: 6100000));
    await _settle(tester);
    expect(find.text('1:41:40 / 2:00:00'), findsOneWidget);
    late.complete(
      http.Response(
        jsonEncode(_session(position: 1000)),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await _settle(tester);
    expect(rig.reads, 2);
    expect(find.text('1:41:40 / 2:00:00'), findsOneWidget);
  });

  testWidgets('an ended tick hides the bar at once', (tester) async {
    final rig = await _pump(tester, session: _session());
    rig.events.add(_tick(ended: true));
    await _settle(tester);
    expect(find.text('A Film'), findsNothing);
    expect(rig.reads, 1);
  });

  testWidgets('a room past the server lifetime is treated as over', (
    tester,
  ) async {
    await _pump(tester, session: _session());
    // Sampled 2s before the read, with a 30s lifetime.
    _advance(const Duration(seconds: 27));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('A Film'), findsOneWidget);
    _advance(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('A Film'), findsNothing);
  });

  testWidgets('a session the client cannot parse is an error, not silence', (
    tester,
  ) async {
    final rig = await _pump(tester, session: _session()..remove('title'));
    final state = rig.container.read(watchRoomProvider('call-1'));
    expect(state.hasError, isTrue);
    expect(find.text('A Film'), findsNothing);
  });

  testWidgets('a phone width ellipsizes the title instead of overflowing', (
    tester,
  ) async {
    await _pump(tester, session: _session()..['title'] = 'T' * 200, width: 280);
    expect(tester.takeException(), isNull);
  });
}
