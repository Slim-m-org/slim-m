// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opt-in voice notices on the client (decision 0107): the choice, its menu, the banner.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/row_menu_notifications.dart';
import 'package:slimm_app/src/features/voice/providers/voice_notice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_notification_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_notice_banner_host.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Server {
  final List<http.Request> puts = [];
  bool failPuts = false;

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'GET') {
      return _json([
        {'channel_id': 'lounge', 'joins': 'first', 'streams': false},
      ]);
    }
    puts.add(request);
    if (failPuts) return http.Response('{"error":"no"}', 500);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return _json({'channel_id': request.url.pathSegments.last, ...body});
  }
}

ProviderContainer _container(
  _Server server, {
  Stream<api.ServerEvent>? events,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events ?? const Stream.empty()),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _loaded(ProviderContainer container) async {
  container.listen(voiceNotificationProvider, (_, _) {});
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('the choice is read from the server and defaults to off', () async {
    final container = _container(_Server());
    await _loaded(container);

    final state = container.read(voiceNotificationProvider);
    expect(state.forChannel('lounge').joins, api.VoiceJoinMode.first);
    expect(state.forChannel('other').joins, api.VoiceJoinMode.off);
    expect(state.forChannel('other').streams, isFalse);
  });

  test('a change is sent whole and a channel left off is dropped', () async {
    final server = _Server();
    final container = _container(server);
    await _loaded(container);
    final notifier = container.read(voiceNotificationProvider.notifier);

    await notifier.setStreams('lounge', streams: true);
    expect(jsonDecode(server.puts.last.body), {
      'joins': 'first',
      'streams': true,
    });

    await notifier.setJoins('lounge', api.VoiceJoinMode.off);
    await notifier.setStreams('lounge', streams: false);
    expect(container.read(voiceNotificationProvider).byChannel, isEmpty);
    expect(jsonDecode(server.puts.last.body), {
      'joins': 'off',
      'streams': false,
    });
  });

  test('a refused change rolls back and says so', () async {
    final server = _Server()..failPuts = true;
    final container = _container(server);
    await _loaded(container);
    final notifier = container.read(voiceNotificationProvider.notifier);

    await expectLater(
      notifier.setJoins('lounge', api.VoiceJoinMode.every),
      throwsA(anything),
    );
    expect(
      container.read(voiceNotificationProvider).forChannel('lounge').joins,
      api.VoiceJoinMode.first,
    );
  });

  testWidgets(
    'the menu marks the current choice and a tap on it turns it off',
    (tester) async {
      final server = _Server();
      final container = _container(server);
      container.listen(voiceNotificationProvider, (_, _) {});
      await tester.pump();
      await tester.pump();
      late List<Widget> items;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Builder(
              builder: (context) {
                items = voiceNotificationMenuItems(
                  context,
                  container,
                  'lounge',
                  () {},
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      final entries = items.whereType<AppMenuItem>().toList();
      expect(entries.map((e) => e.label), [
        'Notify when a call starts',
        'Notify on every join',
        'Notify when someone streams',
      ]);
      expect(entries.map((e) => e.selected), [true, false, false]);

      entries.first.onTap!();
      await tester.pump();
      await tester.pump();
      expect(jsonDecode(server.puts.last.body), {
        'joins': 'off',
        'streams': false,
      });
    },
  );

  test('the notice says who did what and where', () {
    expect(
      voiceNoticeText(api.VoiceActivity.callStarted, 'Ada', 'lounge'),
      'Ada started a call in #lounge',
    );
    expect(
      voiceNoticeText(api.VoiceActivity.joined, 'Ada', 'lounge'),
      'Ada joined #lounge',
    );
    expect(
      voiceNoticeText(api.VoiceActivity.streaming, 'Ada', 'lounge'),
      'Ada is streaming in #lounge',
    );
  });

  testWidgets('the banner opens the channel without joining, or is dismissed', (
    tester,
  ) async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = _container(_Server(), events: events.stream);
    String? opened;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: VoiceNoticeBannerHost(child: Text('shell'))),
        ),
        GoRoute(
          path: '/channels/:id',
          builder: (context, state) {
            opened = state.uri.toString();
            return const Text('channel');
          },
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    );
    expect(find.byKey(const Key('voice-notice-text')), findsNothing);

    container.read(voiceNoticeProvider.notifier).state = const VoiceNoticeItem(
      channelId: 'lounge',
      text: 'Ada started a call in #lounge',
    );
    await tester.pump();
    expect(find.text('Ada started a call in #lounge'), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-notice-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('voice-notice-text')), findsNothing);

    container.read(voiceNoticeProvider.notifier).state = const VoiceNoticeItem(
      channelId: 'lounge',
      text: 'Ada joined #lounge',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-notice-open')));
    await tester.pump();
    await tester.pump();
    expect(opened, contains('/channels/lounge'));
    expect(opened, contains('chat=1'), reason: 'arrives without joining');
  });
}
