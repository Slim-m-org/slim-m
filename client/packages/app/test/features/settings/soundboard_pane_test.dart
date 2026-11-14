// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings Soundboard section: add, rename and remove clips.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_intake.dart';
import 'package:slimm_app/src/features/settings/screens/admin/soundboard_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'user-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

final _json = {'content-type': 'application/json'};

class _Wire {
  final clips = <Map<String, Object?>>[
    {'id': 'clip-1', 'name': 'Air horn', 'duration_ms': 1500, 'created_at': 1},
  ];
  final writes = <String>[];
  String? uploadFailure;

  Map<String, Object?> _clip(String id, String name) => {
    'id': id,
    'name': name,
    'duration_ms': 2000,
    'created_at': 5,
  };

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/soundboard') {
      return http.Response(jsonEncode(clips), 200, headers: _json);
    }
    if (request.method == 'POST' && path == '/soundboard') {
      writes.add(
        'POST ${request.url.queryParameters['name']} ${request.bodyBytes.length}',
      );
      if (uploadFailure case final failure?) {
        return http.Response(
          jsonEncode({'error': failure}),
          400,
          headers: _json,
        );
      }
      clips.add(_clip('clip-9', request.url.queryParameters['name']!));
      return http.Response(jsonEncode(clips.last), 201, headers: _json);
    }
    if (request.method == 'PATCH' && path == '/soundboard/clip-1') {
      final name = (jsonDecode(request.body) as Map)['name'] as String;
      writes.add('PATCH $name');
      clips[0] = _clip('clip-1', name);
      return http.Response(jsonEncode(clips[0]), 200, headers: _json);
    }
    if (request.method == 'DELETE' && path == '/soundboard/clip-1') {
      writes.add('DELETE');
      clips.clear();
      return http.Response('', 204);
    }
    return http.Response('{}', 404);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Wire wire, {
  SoundClipPick? pick,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride(wire.handle),
        soundClipPickerProvider.overrideWithValue(() async => pick),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: SoundboardPane()),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

void main() {
  testWidgets('lists the clips with their lengths and the count', (
    tester,
  ) async {
    await _pump(tester, _Wire());
    expect(find.text('Clips (1 of 48)'), findsOneWidget);
    expect(find.text('Air horn'), findsOneWidget);
    expect(find.text('1.5 s'), findsOneWidget);
  });

  testWidgets('adding a file uploads it under its file name', (tester) async {
    final wire = _Wire();
    await _pump(
      tester,
      wire,
      pick: SoundClipPick(
        fileName: 'sad trombone.mp3',
        bytes: List.filled(1000, 1),
      ),
    );
    await tester.tap(find.text('Add clip'));
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['POST sad trombone 1000']);
    expect(find.text('sad trombone'), findsOneWidget);
  });

  testWidgets('a file over 512 KB is refused before it is sent', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(
      tester,
      wire,
      pick: SoundClipPick(
        fileName: 'huge.wav',
        bytes: List.filled(512 * 1024 + 1, 0),
      ),
    );
    await tester.tap(find.text('Add clip'));
    await pumpFrames(tester);

    expect(wire.writes, isEmpty);
    expect(find.textContaining('over 512 KB'), findsOneWidget);
  });

  testWidgets("the server's refusal shows inline", (tester) async {
    final wire = _Wire()..uploadFailure = 'clip must be at most 5 seconds';
    await _pump(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'long.wav', bytes: [1]),
    );
    await tester.tap(find.text('Add clip'));
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(find.textContaining('Could not add the clip'), findsOneWidget);
  });

  testWidgets('renaming saves the new name', (tester) async {
    final wire = _Wire();
    await _pump(tester, wire);
    await tester.tap(find.bySemanticsLabel('Rename Air horn'));
    await pumpFrames(tester, frames: 20);
    await tester.enterText(
      find.byWidgetPredicate((w) => w is EditableText),
      'Honk',
    );
    await tester.pump();
    await tester.tap(find.text('Save name'));
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['PATCH Honk']);
    expect(find.text('Honk'), findsOneWidget);
  });

  testWidgets('removing asks first, then deletes', (tester) async {
    final wire = _Wire();
    await _pump(tester, wire);
    await tester.tap(find.bySemanticsLabel('Remove Air horn'));
    await pumpFrames(tester, frames: 20);
    expect(wire.writes, isEmpty, reason: 'confirm first');

    await tester.tap(find.text('Remove'));
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['DELETE']);
    expect(find.text('No clips yet.'), findsOneWidget);
  });
}
