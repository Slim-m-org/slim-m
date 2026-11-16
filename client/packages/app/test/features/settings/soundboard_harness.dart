// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Soundboard pane mounted over an in-memory `/soundboard`, shared by its
/// list tests and its clip sheet tests.
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

const partyEmojiId = '01900000-0000-7000-8000-00000000e001';

/// The server side of `/soundboard`, `/emoji` and `/users`, recording each write.
class SoundboardWire {
  SoundboardWire({bool seeded = false, this.custom = false}) {
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

  /// Answers `/emoji` with one custom emoji, so the picker opens on it.
  final bool custom;

  final clips = <Map<String, Object?>>[
    {'id': 'clip-1', 'name': 'Air horn', 'duration_ms': 1500, 'created_at': 1},
  ];
  final writes = <String>[];
  String? uploadFailure;

  Map<String, Object?> _clip(String id, String name, Object? emoji) => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'duration_ms': 2000,
    'created_at': 5,
  };

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/soundboard') {
      return http.Response(jsonEncode(clips), 200, headers: _json);
    }
    if (request.method == 'GET' && path == '/emoji') {
      return http.Response(
        jsonEncode([
          if (custom)
            {
              'id': partyEmojiId,
              'name': 'party_parrot',
              'uploader_id': null,
              'created_at': 1,
            },
        ]),
        200,
        headers: _json,
      );
    }
    if (request.method == 'GET' && path.startsWith('/emoji/')) {
      return http.Response('', 404);
    }
    if (request.method == 'GET' && path == '/users') {
      return http.Response(
        jsonEncode([
          {
            'id': 'user-nick',
            'username': 'nick',
            'display_name': 'Nick',
            'created_at': 1,
          },
        ]),
        200,
        headers: _json,
      );
    }
    if (request.method == 'GET' && path == '/soundboard/clip-1/audio') {
      return http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'audio/wav'},
      );
    }
    if (request.method == 'POST' && path == '/soundboard') {
      final query = request.url.queryParameters;
      final emoji = query['emoji'];
      writes.add(
        'POST ${query['name']} ${request.bodyBytes.length}'
        '${emoji == null ? '' : ' $emoji'}',
      );
      if (uploadFailure case final failure?) {
        return http.Response(
          jsonEncode({'error': failure}),
          400,
          headers: _json,
        );
      }
      clips.add(_clip('clip-9', query['name']!, emoji));
      return http.Response(jsonEncode(clips.last), 201, headers: _json);
    }
    if (request.method == 'PATCH' && path == '/soundboard/clip-1') {
      final body = jsonDecode(request.body) as Map;
      writes.add('PATCH ${body['name']} ${body['emoji']}');
      clips[0] = _clip('clip-1', body['name'] as String, body['emoji']);
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

/// Keeps what it was asked to play instead of playing it.
class RecordingClipPlayer implements SoundClipPlayer {
  final played = <({List<int> bytes, String mimeType, double volume})>[];

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) async => played.add((bytes: bytes, mimeType: mimeType, volume: volume));
}

/// Mounts the pane; the picker hands out [picks] in turn, then [pick].
Future<void> pumpSoundboard(
  WidgetTester tester,
  SoundboardWire wire, {
  SoundClipPick? pick,
  List<SoundClipPick>? picks,
  SoundClipPlayer? player,
  double width = 1280,
}) async {
  final queue = [...?picks];
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride(wire.handle),
        soundClipPickerProvider.overrideWithValue(
          () async => queue.isEmpty ? pick : queue.removeAt(0),
        ),
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

Finder get soundboardTitleBar => find.byWidgetPredicate((w) => w is AppBar);

/// The title bar's Create clip, which opens the clip sheet.
Finder get soundboardCreateButton => find.descendant(
  of: soundboardTitleBar,
  matching: find.widgetWithText(AppButton, 'Create clip'),
);

/// The sheet's own Create clip, which uploads.
Finder get sheetCreateButton =>
    find.widgetWithText(AppButton, 'Create clip').last;

Finder get sheetSaveButton => find.widgetWithText(AppButton, 'Save');

Finder get clipEmojiButton =>
    find.bySemanticsLabel('Choose an emoji for the clip');

const grinningFace = '\u{1F600}';

Finder get clipNameField => find.byWidgetPredicate((w) => w is EditableText);

Future<void> openCreateClip(WidgetTester tester) async {
  await tester.tap(soundboardCreateButton);
  await pumpFrames(tester, frames: 20);
}
