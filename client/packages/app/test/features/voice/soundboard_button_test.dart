// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard control in a call: who sees it, how it opens at each width,
/// what a tap sends, how the rate limit rests the rows, and what a refusal says.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/widgets/soundboard_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/hover_reveal.dart';
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
  _Wire({this.clips = _defaultClips, this.playStatus = 204});

  static const _defaultClips = [
    {'id': 'clip-1', 'name': 'Air horn', 'duration_ms': 1500, 'created_at': 1},
    {
      'id': 'clip-2',
      'name': 'Sad trombone',
      'duration_ms': 3200,
      'created_at': 2,
    },
  ];

  final List<Map<String, Object?>> clips;
  final int playStatus;
  final plays = <String>[];

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/soundboard') {
      return http.Response(jsonEncode(clips), 200, headers: _json);
    }
    if (request.method == 'POST' && path.endsWith('/play')) {
      plays.add(path);
      return http.Response(
        playStatus == 204 ? '' : jsonEncode({'error': 'slow down and retry'}),
        playStatus,
        headers: _json,
      );
    }
    return http.Response('{}', 404);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Wire wire, {
  double width = 1280,
  ValueChanged<bool>? pin,
}) async {
  const button = Align(
    alignment: Alignment.bottomCenter,
    child: Padding(
      padding: EdgeInsets.all(16),
      child: SoundboardButton(channelId: 'c1'),
    ),
  );
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride(wire.handle),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: pin == null
              ? button
              : HoverRevealScope(
                  pin: pin,
                  reportMenuOpen: (_) {},
                  reportOverlayHover: (_) {},
                  child: button,
                ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Soundboard'));
  await pumpFrames(tester, frames: 20);
}

void main() {
  testWidgets('on a wide layout the clips open in a popover above the button', (
    tester,
  ) async {
    await _pump(tester, _Wire());
    await _open(tester);

    final row = tester.getRect(find.text('Air horn'));
    final button = tester.getRect(find.byTooltip('Soundboard'));
    expect(row.bottom, lessThan(button.top), reason: 'above the dock');
    expect(tester.getRect(find.text('Sad trombone')).width, lessThan(280));
    expect(find.text('1.5 s'), findsOneWidget);
    expect(find.text('3.2 s'), findsOneWidget);
  });

  testWidgets('on a phone the same rows open as a bottom sheet', (
    tester,
  ) async {
    await _pump(tester, _Wire(), width: 390);
    await _open(tester);

    expect(find.text('Air horn'), findsOneWidget);
    expect(
      tester.getRect(find.text('1.5 s')).right,
      greaterThan(340),
      reason: 'the duration sits at the far edge of a full-width row',
    );
  });

  testWidgets('tapping a clip asks the server to play it into this call', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, wire);
    await _open(tester);

    await tester.tap(find.text('Sad trombone'));
    await waitUntil(tester, () => wire.plays.isNotEmpty);

    expect(wire.plays, ['/channels/c1/voice/soundboard/clip-2/play']);
    expect(find.text('Sad trombone'), findsOneWidget, reason: 'stays open');
  });

  testWidgets('a play rests the rows for 3 s, then they come back', (
    tester,
  ) async {
    final wire = _Wire();
    await _pump(tester, wire);
    await _open(tester);

    await tester.tap(find.text('Air horn'));
    await waitUntil(tester, () => wire.plays.isNotEmpty);
    await tester.tap(find.text('Sad trombone'));
    await pumpFrames(tester);
    expect(wire.plays, hasLength(1), reason: 'inside the rest');

    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Sad trombone'));
    await waitUntil(tester, () => wire.plays.length == 2);
    expect(wire.plays.last, '/channels/c1/voice/soundboard/clip-2/play');
  });

  testWidgets('the rate limit reads as the rest, never as an error', (
    tester,
  ) async {
    final wire = _Wire(playStatus: 429);
    await _pump(tester, wire);
    await _open(tester);

    await tester.tap(find.text('Air horn'));
    await waitUntil(tester, () => wire.plays.isNotEmpty);
    await pumpFrames(tester);

    expect(find.textContaining('Could not play'), findsNothing);
    await tester.tap(find.text('Sad trombone'));
    await pumpFrames(tester);
    expect(wire.plays, hasLength(1), reason: 'the rows are resting');
  });

  testWidgets('any other refusal says so next to the clips', (tester) async {
    final wire = _Wire(playStatus: 403);
    await _pump(tester, wire);
    await _open(tester);

    await tester.tap(find.text('Air horn'));
    await waitUntil(tester, () => wire.plays.isNotEmpty);
    await pumpFrames(tester);

    expect(find.textContaining('Could not play Air horn'), findsOneWidget);
    await tester.tap(find.text('Sad trombone'));
    await waitUntil(tester, () => wire.plays.length == 2);
    expect(wire.plays, hasLength(2), reason: 'a refusal starts no rest');
  });

  testWidgets('the open menu keeps a collapsible call dock revealed', (
    tester,
  ) async {
    final pins = <bool>[];
    await _pump(tester, _Wire(), pin: pins.add);
    await _open(tester);
    expect(pins, [true]);

    await tester.tap(find.byTooltip('Soundboard'));
    await pumpFrames(tester, frames: 20);
    expect(pins, [true, false]);
  });

  testWidgets('a Space with no clips says so', (tester) async {
    await _pump(tester, _Wire(clips: const []));
    await _open(tester);
    expect(find.textContaining('No clips yet'), findsOneWidget);
  });

  testWidgets(
    'only a member holding SPEAK and USE_SOUNDBOARD in the channel gets the button',
    (tester) async {
      Future<bool> seen(int permissions) async {
        late bool shown;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              myChannelPermissionsProvider('c1').overrideWithValue(permissions),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) {
                  shown = canUseSoundboard(ref, 'c1');
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        return shown;
      }

      expect(await seen(Perm.connect | Perm.speak), isFalse);
      expect(await seen(Perm.connect | Perm.useSoundboard), isFalse);
      expect(
        await seen(Perm.connect | Perm.speak | Perm.useSoundboard),
        isTrue,
      );
    },
  );
}
