// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's two kinds of async work: the message search a keystroke
/// starts, and the request a chosen result makes. Each is held open with a
/// completer, so the test decides when the server answers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';
import '../../support/fake_api.dart';

const _input = Key('command-palette-input');

const _hit = {
  'id': 'm1',
  'channel_id': 'ch1',
  'author_id': 'other',
  'author_display_name': 'Ren',
  'seq': 1,
  'content': 'foo bar baz',
  'created_at': 0,
  'edited_at': null,
};

MockClientHandler _server({
  Completer<void>? searchGate,
  Completer<void>? dmGate,
  int dmStatus = 200,
  List<String>? dmPosts,
}) => (request) async {
  if (request.url.path == '/blocks') return http.Response('[]', 200);
  if (request.url.path == '/search/messages') {
    await searchGate?.future;
    return http.Response(jsonEncode([_hit]), 200);
  }
  if (request.method == 'POST' && request.url.path == '/dms/other') {
    dmPosts?.add(request.url.path);
    await dmGate?.future;
    if (dmStatus != 200) {
      return http.Response(jsonEncode({'error': 'denied'}), dmStatus);
    }
    return http.Response(
      jsonEncode({
        'channel_id': 'dm-1',
        'user': {
          'id': 'other',
          'username': 'ren',
          'display_name': 'Ren',
          'created_at': 0,
        },
        'unread': 0,
        'created_at': 0,
      }),
      200,
    );
  }
  throw StateError('unexpected request in this test: ${request.url}');
};

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester,
  MockClientHandler handler,
) async {
  final setup = setupPalette(overrides: [mockApiOverride(handler)]);
  await MessageStore(setup.db).upsertChannels(const [
    api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pump(tester, setup.container, initial: '/channels/ch1');
  await pressCtrlK(tester);
  return setup;
}

void main() {
  testWidgets('closing the palette mid-search leaves no unhandled error', (
    tester,
  ) async {
    final gate = Completer<void>();
    final setup = await _open(tester, _server(searchGate: gate));

    await tester.enterText(find.byKey(_input), 'foo');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(tester);
    expect(find.byKey(_input), findsNothing);

    gate.complete();
    await _frames(tester);
    expect(tester.takeException(), isNull);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('clearing the field drops the hits of a search still in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    final setup = await _open(tester, _server(searchGate: gate));

    await tester.enterText(find.byKey(_input), 'foo');
    await tester.pump();
    await tester.enterText(find.byKey(_input), '');
    await tester.pump();

    gate.complete();
    await _frames(tester);
    expect(inPalette('foo bar baz'), findsNothing);
    expect(inPalette('MESSAGES'), findsNothing);
    expect(inPalette('CHANNELS'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('a failed DM open says so inside the palette and stays open', (
    tester,
  ) async {
    final setup = await _open(tester, _server(dmStatus: 403));

    await tester.tap(inPalette('Ren'));
    await _frames(tester);

    expect(find.byKey(_input), findsOneWidget);
    expect(
      inPalette('Could not message Ren: you are not allowed to do that.'),
      findsOneWidget,
    );
    expect(find.text('Dismiss'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await _frames(tester);
    expect(
      inPalette('Could not message Ren: you are not allowed to do that.'),
      findsNothing,
    );

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('typing again clears the failure of the last run', (
    tester,
  ) async {
    final setup = await _open(tester, _server(dmStatus: 403));

    await tester.tap(inPalette('Ren'));
    await _frames(tester);
    await tester.enterText(find.byKey(_input), 'ren');
    await _frames(tester);

    expect(find.text('Dismiss'), findsNothing);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets(
    'a second Enter or tap while a result runs does not run it again',
    (tester) async {
      final gate = Completer<void>();
      final posts = <String>[];
      final setup = await _open(tester, _server(dmGate: gate, dmPosts: posts));

      await tester.tap(inPalette('Ren'));
      await tester.pump();
      await tester.tap(inPalette('Ren'));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(posts, hasLength(1));

      gate.complete();
      await _frames(tester);
      expect(find.byKey(_input), findsNothing);
      final context = tester.element(find.text('conversation').first);
      expect(GoRouterState.of(context).uri.path, '/channels/dm-1');
      expect(posts, hasLength(1));

      await teardown(tester, setup.container, setup.db);
    },
  );
}
