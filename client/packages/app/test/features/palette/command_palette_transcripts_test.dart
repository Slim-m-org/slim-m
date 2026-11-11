// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Transcript lines in the palette (decision 0113): a "Transcripts" group from
/// `/search/transcripts`, and choosing a hit opening that voice channel to read
/// with the line queued for the idle pane.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_transcript.dart';
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';
import '../../support/fake_api.dart';

const _input = Key('command-palette-input');

const _hit = {
  'transcript_id': 't1',
  'channel_id': 'vc1',
  'seq': 12,
  'speaker_id': 'other',
  'at': 1700000000000,
  'text': 'we should ship it friday',
  'highlight': 'we should <mark>ship</mark> it friday',
};

MockClientHandler _server({
  List<String>? paths,
  bool transcriptsForbidden = false,
}) => (request) async {
  paths?.add(request.url.path);
  switch (request.url.path) {
    case '/blocks':
      return http.Response('[]', 200);
    case '/search/messages':
      return http.Response('[]', 200);
    case '/search/transcripts':
      if (transcriptsForbidden) {
        return http.Response(jsonEncode({'error': 'denied'}), 403);
      }
      return http.Response(jsonEncode([_hit]), 200);
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
  MockClientHandler handler, {
  Size size = const Size(1400, 900),
}) async {
  final setup = setupPalette(overrides: [mockApiOverride(handler)]);
  await MessageStore(setup.db).upsertChannels(const [
    api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    api.Channel(id: 'vc1', name: 'lounge', kind: 'voice', createdAt: 0),
  ]);
  await pump(tester, setup.container, initial: '/channels/ch1', size: size);
  await pressCtrlK(tester);
  return setup;
}

void main() {
  testWidgets(
    'a search shows a Transcripts group with the line and its place',
    (tester) async {
      final setup = await _open(tester, _server());

      await tester.enterText(find.byKey(_input), 'ship');
      await _frames(tester);

      expect(inPalette('TRANSCRIPTS'), findsOneWidget);
      expect(find.textContaining('#lounge'), findsOneWidget);

      await teardown(tester, setup.container, setup.db);
    },
  );

  testWidgets('a hit opens the voice channel to read and queues its line', (
    tester,
  ) async {
    final setup = await _open(tester, _server());
    await tester.enterText(find.byKey(_input), 'ship');
    await _frames(tester);

    await tester.tap(find.textContaining('#lounge'));
    await _frames(tester);

    final router = GoRouter.of(tester.element(find.text('conversation')));
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/channels/vc1?chat=1',
    );
    expect(setup.container.read(transcriptFocusProvider), (
      channelId: 'vc1',
      transcriptId: 't1',
      seq: 12,
    ));

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('a refused transcript search leaves the other groups alone', (
    tester,
  ) async {
    final setup = await _open(tester, _server(transcriptsForbidden: true));

    await tester.enterText(find.byKey(_input), 'ship');
    await _frames(tester);

    expect(inPalette('TRANSCRIPTS'), findsNothing);
    expect(find.text('No matches.'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('at phone width the group and its rows still draw', (
    tester,
  ) async {
    final setup = await _open(tester, _server(), size: const Size(390, 800));

    await tester.enterText(find.byKey(_input), 'ship');
    await _frames(tester);

    expect(inCompactPalette('TRANSCRIPTS'), findsOneWidget);
    expect(find.textContaining('#lounge'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });
}
