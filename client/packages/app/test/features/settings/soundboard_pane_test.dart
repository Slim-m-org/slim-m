// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings Soundboard section: create, listen to, rename and
/// remove clips.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/sound_clip_player.dart';
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
  _Wire({bool seeded = false}) {
    if (seeded) {
      clips.add({
        'id': 'clip-0',
        'name': 'Rimshot',
        'duration_ms': 800,
        'uploader_id': null,
        'created_at': 0,
      });
    }
  }

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
    if (request.method == 'GET' && path == '/soundboard/clip-1/audio') {
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'audio/wav'},
      );
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
    writes.add('${request.method} $path');
    return http.Response('{}', 404);
  }
}

class _RecordingPlayer implements SoundClipPlayer {
  final played = <({List<int> bytes, String mimeType, double volume})>[];

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) async => played.add((bytes: bytes, mimeType: mimeType, volume: volume));
}

Future<void> _pump(
  WidgetTester tester,
  _Wire wire, {
  SoundClipPick? pick,
  SoundClipPlayer? player,
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
        if (player != null) soundClipPlayerProvider.overrideWithValue(player),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SoundboardScreen(),
      ),
    ),
  );
  await pumpFrames(tester);
}

Finder get _titleBar => find.byWidgetPredicate((w) => w is AppBar);

/// The title bar's Create clip, which opens the naming sheet.
Finder get _createButton => find.descendant(
  of: _titleBar,
  matching: find.widgetWithText(AppButton, 'Create clip'),
);

/// The sheet's own Create clip, which uploads.
Finder get _sheetCreate => find.widgetWithText(AppButton, 'Create clip').last;

Finder get _nameField => find.byWidgetPredicate((w) => w is EditableText);

Future<void> _openCreate(WidgetTester tester) async {
  await tester.tap(_createButton);
  await pumpFrames(tester, frames: 20);
}

void main() {
  testWidgets('lists the clips with their lengths under a plain title', (
    tester,
  ) async {
    await _pump(tester, _Wire());
    expect(find.text('Clips'), findsOneWidget);
    expect(find.text('1 of 48'), findsOneWidget);
    expect(find.text('Air horn'), findsOneWidget);
    expect(find.text('1.5 s'), findsOneWidget);
  });

  testWidgets(
    'a clip the server seeded with no uploader renders like any other',
    (tester) async {
      await _pump(tester, _Wire(seeded: true));
      expect(find.text('Rimshot'), findsOneWidget);
      expect(find.text('0.8 s'), findsOneWidget);
      expect(find.bySemanticsLabel('Rename Rimshot'), findsOneWidget);
      expect(find.text('2 of 48'), findsOneWidget);
    },
  );

  testWidgets('Create clip sits in the title bar at its own width', (
    tester,
  ) async {
    await _pump(tester, _Wire());
    expect(_createButton, findsOneWidget);
    final bar = tester.getRect(_titleBar);
    final button = tester.getRect(_createButton);
    expect(bar.contains(button.center), isTrue);
    expect(
      button.width,
      lessThan(bar.width / 3),
      reason: 'never a full-width bar',
    );
  });

  testWidgets('creating asks for a name first, prefilled from the file', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(
      tester,
      wire,
      pick: SoundClipPick(
        fileName: 'sad trombone.mp3',
        bytes: List.filled(1000, 1),
      ),
    );
    await _openCreate(tester);

    expect(wire.writes, isEmpty, reason: 'nothing is sent before it is named');
    expect(find.text('sad trombone.mp3'), findsOneWidget);
    expect(
      tester.widget<EditableText>(_nameField).controller.text,
      'sad trombone',
    );

    await tester.enterText(_nameField, 'Trombone');
    await tester.pump();
    await tester.tap(_sheetCreate);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['POST Trombone 1000']);
    expect(find.text('Trombone'), findsOneWidget);
    expect(find.text('sad trombone.mp3'), findsNothing, reason: 'closed');
  });

  testWidgets('a taken name is flagged before sending and fixed in place', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'AIR HORN.wav', bytes: [1]),
    );
    await _openCreate(tester);

    expect(find.text('A clip already has that name.'), findsOneWidget);
    await tester.tap(_sheetCreate);
    await pumpFrames(tester);
    expect(wire.writes, isEmpty, reason: 'a taken name is never sent');

    await tester.enterText(_nameField, 'Air horn 2');
    await tester.pump();
    expect(find.text('A clip already has that name.'), findsNothing);
    await tester.tap(_sheetCreate);
    await waitUntil(tester, () => wire.writes.isNotEmpty);

    expect(wire.writes, ['POST Air horn 2 1']);
  });

  testWidgets("the server's refusal stays on the sheet with the file kept", (
    tester,
  ) async {
    final wire = _Wire()..uploadFailure = 'clip must be at most 5 seconds';
    await _pump(
      tester,
      wire,
      pick: const SoundClipPick(fileName: 'long.wav', bytes: [1, 2]),
    );
    await _openCreate(tester);
    await tester.tap(_sheetCreate);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(find.textContaining('Could not create the clip'), findsOneWidget);
    expect(find.text('long.wav'), findsOneWidget, reason: 'still open');

    wire.uploadFailure = null;
    await tester.tap(_sheetCreate);
    await waitUntil(tester, () => wire.writes.length == 2);
    await pumpFrames(tester);

    expect(wire.writes, ['POST long 2', 'POST long 2']);
    expect(find.text('long.wav'), findsNothing);
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
    await _openCreate(tester);
    await tester.tap(_sheetCreate);
    await pumpFrames(tester);

    expect(wire.writes, isEmpty);
    expect(find.textContaining('over 512 KB'), findsOneWidget);
  });

  testWidgets('renaming opens the shared sheet and saves the new name', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, wire);
    await tester.tap(find.bySemanticsLabel('Rename Air horn'));
    await pumpFrames(tester, frames: 20);

    expect(find.text('Rename Air horn'), findsWidgets);
    expect(find.byTooltip('Close'), findsOneWidget);
    final save = find.widgetWithText(AppButton, 'Save name');
    expect(
      tester.getRect(save).width,
      moreOrLessEquals(tester.getRect(_nameField).width, epsilon: 40),
      reason: 'Save spans the sheet',
    );

    await tester.enterText(_nameField, 'Honk');
    await tester.pump();
    await tester.tap(save);
    await waitUntil(tester, () => wire.writes.isNotEmpty);
    await pumpFrames(tester);

    expect(wire.writes, ['PATCH Honk']);
    expect(find.text('Honk'), findsOneWidget);
  });

  testWidgets('listening plays the clip here and sends nothing to a call', (
    tester,
  ) async {
    final wire = _Wire();
    final player = _RecordingPlayer();
    await _pump(tester, wire, player: player);

    await tester.tap(find.bySemanticsLabel('Listen to Air horn'));
    await waitUntil(tester, () => player.played.isNotEmpty);

    expect(player.played.single.bytes, [1, 2, 3]);
    expect(player.played.single.mimeType, 'audio/wav');
    expect(wire.writes, isEmpty, reason: 'no /play reaches the server');
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
