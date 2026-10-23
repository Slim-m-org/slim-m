// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster's badge store: ids asked for in one frame ride shared requests
/// of at most 100, an answer is reused for a minute, and a removed member is
/// forgotten.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/module_badges.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

typedef _Rig = ({
  ProviderContainer container,
  List<List<String>> asked,
  StreamController<api.ServerEvent> events,
  DateTime Function() clock,
  void Function(Duration) advance,
});

_Rig _rig({bool fail = false}) {
  final asked = <List<String>>[];
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  var now = DateTime(2026, 10, 23, 12);
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      moduleBadgesClockProvider.overrideWithValue(() => now),
      mockApiOverride((request) async {
        final ids = request.url.queryParameters['ids']!.split(',');
        asked.add(ids);
        if (fail) return http.Response('{}', 500);
        return http.Response(
          jsonEncode({
            'badges': {
              for (final id in ids.where((id) => id.startsWith('b')))
                id: [
                  {
                    'module_id': 'm',
                    'name': 'level',
                    'nodes': [
                      {'type': 'badge', 'text': 'L1'},
                    ],
                  },
                ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    asked: asked,
    events: events,
    clock: () => now,
    advance: (d) => now = now.add(d),
  );
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('150 ids asked in one frame make two requests, 100 and 50', () async {
    final rig = _rig();
    final store = rig.container.read(moduleBadgesProvider.notifier);

    for (var i = 0; i < 150; i++) {
      store.request('u$i');
    }
    await _settle();

    expect(rig.asked.map((ids) => ids.length).toList()..sort(), [50, 100]);
  });

  test(
    'a member with badges is held and a bare one holds an empty list',
    () async {
      final rig = _rig();
      final store = rig.container.read(moduleBadgesProvider.notifier);

      store.request('b1');
      store.request('plain');
      await _settle();

      final held = rig.container.read(moduleBadgesProvider);
      expect(held['b1'], hasLength(1));
      expect(held['plain'], isEmpty);
    },
  );

  test('an answer under a minute old is not asked for again', () async {
    final rig = _rig();
    final store = rig.container.read(moduleBadgesProvider.notifier);

    store.request('b1');
    await _settle();
    rig.advance(const Duration(seconds: 59));
    store.request('b1');
    await _settle();

    expect(rig.asked, hasLength(1));
  });

  test('an answer a minute old is refetched', () async {
    final rig = _rig();
    final store = rig.container.read(moduleBadgesProvider.notifier);

    store.request('b1');
    await _settle();
    rig.advance(const Duration(seconds: 61));
    store.request('b1');
    await _settle();

    expect(rig.asked, hasLength(2));
  });

  test('a removed member is evicted and asked for afresh', () async {
    final rig = _rig();
    final store = rig.container.read(moduleBadgesProvider.notifier);

    store.request('b1');
    await _settle();
    rig.events.add(const api.MemberRemoved(userId: 'b1'));
    await _settle();

    expect(rig.container.read(moduleBadgesProvider), isNot(contains('b1')));
    store.request('b1');
    await _settle();
    expect(rig.asked, hasLength(2));
  });

  test(
    'a failed request holds nothing and is not retried inside the minute',
    () async {
      final rig = _rig(fail: true);
      final store = rig.container.read(moduleBadgesProvider.notifier);

      store.request('b1');
      await _settle();
      store.request('b1');
      await _settle();

      expect(rig.container.read(moduleBadgesProvider), isEmpty);
      expect(rig.asked, hasLength(1));
    },
  );
}
