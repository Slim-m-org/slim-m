// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard control in a call: who sees it, how its grid of tiles opens
/// at each width, what a tap sends, how the rate limit rests the tiles, and
/// what a refusal says.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/voice/widgets/soundboard_button.dart';
import 'package:slimm_app/src/features/voice/widgets/soundboard_picker.dart';
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

List<Map<String, Object?>> _numbered(int count) => [
  for (var i = 0; i < count; i++)
    {'id': 'c$i', 'name': 'Clip$i', 'duration_ms': 1000, 'created_at': i},
];

Finder get _menu =>
    find.ancestor(of: find.text('Clip0'), matching: _isMenu).first;

final _isMenu = find.byWidgetPredicate((w) => w is AppMenu);

Finder _tile(String id) => find.byKey(ValueKey(id));

bool _dimmed(WidgetTester tester, String id) => find
    .descendant(
      of: _tile(id),
      matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
    )
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets('on a wide layout the clips open in a popover above the button', (
    tester,
  ) async {
    await _pump(tester, _Wire());
    await _open(tester);

    final tile = tester.getRect(_tile('clip-1'));
    final button = tester.getRect(find.byTooltip('Soundboard'));
    expect(tile.bottom, lessThan(button.top), reason: 'above the dock');
    expect(find.bySemanticsLabel('Air horn, 1.5 s'), findsOneWidget);
    expect(find.bySemanticsLabel('Sad trombone, 3.2 s'), findsOneWidget);
    expect(find.byTooltip('Air horn, 1.5 s'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(_tile('clip-1')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Air horn, 1.5 s'), findsNothing, reason: 'no hover tip');
    expect(find.text('Soundboard'), findsNothing, reason: 'no heading');
  });

  testWidgets(
    '12 clips fill four rows of three in a popover about 262 px tall with the volume row',
    (tester) async {
      await _pump(tester, _Wire(clips: _numbered(12)));
      await _open(tester);

      final scroll = Scrollable.of(tester.element(find.text('Clip0')));
      expect(scroll.position.maxScrollExtent, 0, reason: 'no scrolling');
      final tops = {
        for (var i = 0; i < 12; i++) tester.getRect(_tile('c$i')).top,
      };
      expect(tops, hasLength(4), reason: 'four rows');
      for (var i = 0; i < 12; i += 3) {
        expect(
          tester.getRect(_tile('c${i + 2}')).top,
          tester.getRect(_tile('c$i')).top,
          reason: 'three to a row',
        );
      }
      final menu = tester.getRect(_menu);
      expect(menu.width, soundboardMenuWidth);
      expect(menu.height, moreOrLessEquals(262, epsilon: 1));
      expect(
        menu.bottom,
        lessThan(tester.getRect(find.byTooltip('Soundboard')).top),
      );
    },
  );

  testWidgets('48 clips scroll inside the popover', (tester) async {
    await _pump(tester, _Wire(clips: _numbered(48)));
    await _open(tester);

    final scroll = Scrollable.of(tester.element(find.text('Clip0')));
    expect(scroll.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('a tile shows its emoji, a custom one, or the music icon', (
    tester,
  ) async {
    const customId = '01900000-0000-7000-8000-00000000e001';
    await _pump(
      tester,
      _Wire(
        clips: const [
          {
            'id': 'horn',
            'name': 'airhorn',
            'emoji': '\u{1F4EF}',
            'duration_ms': 1400,
            'created_at': 1,
          },
          {
            'id': 'party',
            'name': 'party',
            'emoji': customId,
            'duration_ms': 900,
            'created_at': 2,
          },
          {'id': 'plain', 'name': 'chime', 'duration_ms': 800, 'created_at': 3},
        ],
      ),
    );
    await _open(tester);

    expect(
      find.descendant(of: _tile('horn'), matching: find.text('\u{1F4EF}')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _tile('party'),
        matching: find.byWidgetPredicate(
          (w) => w is CustomEmojiImage && w.emojiId == customId,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _tile('plain'),
        matching: find.byIcon(AppIcons.music),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _tile('horn'), matching: find.byIcon(AppIcons.music)),
      findsNothing,
    );
  });

  testWidgets(
    'on a phone the tiles open in a sheet, touch height, as many across as fit a long name',
    (tester) async {
      await _pump(
        tester,
        _Wire(
          clips: [
            {
              'id': 'buzz',
              'name': 'wrong buzzer',
              'duration_ms': 1100,
              'created_at': 0,
            },
            ..._numbered(11),
          ],
        ),
        width: 390,
      );
      await _open(tester);

      final first = tester.getRect(_tile('buzz'));
      expect(first.height, greaterThanOrEqualTo(44), reason: 'a touch target');
      final row = [
        for (final id in ['buzz', for (var i = 0; i < 11; i++) 'c$i'])
          if (tester.getRect(_tile(id)).top == first.top)
            tester.getRect(_tile(id)),
      ];
      expect(row.length, greaterThan(1), reason: 'side by side');
      final name = tester.renderObject<RenderParagraph>(
        find.text('wrong buzzer'),
      );
      expect(name.didExceedMaxLines, isFalse, reason: 'the name is whole');
      final gap = row[1].left - row[0].right;
      final across = row.last.right - row.first.left;
      final oneMore = (across - gap * row.length) / (row.length + 1);
      expect(
        oneMore,
        lessThan(name.getMaxIntrinsicWidth(double.infinity) + 8),
        reason: 'one more column would cut the name',
      );
    },
  );

  for (final width in [390.0, 1280.0]) {
    testWidgets('at $width a long name wraps whole with no tooltip', (
      tester,
    ) async {
      const long = 'a very long clip name here ok';
      await _pump(
        tester,
        _Wire(
          clips: [
            {'id': 'long', 'name': long, 'duration_ms': 1100, 'created_at': 0},
          ],
        ),
        width: width,
      );
      final semantics = tester.ensureSemantics();
      await _open(tester);

      expect(
        find.ancestor(
          of: _tile('long'),
          matching: find.byWidgetPredicate((w) => w is Tooltip),
        ),
        findsNothing,
      );
      expect(find.byTooltip('$long, 1.1 s'), findsNothing);
      final name = tester.renderObject<RenderParagraph>(find.text(long));
      expect(name.didExceedMaxLines, isFalse, reason: 'the name is whole');
      expect(find.bySemanticsLabel('$long, 1.1 s'), findsOneWidget);
      expect(
        width > 600 ||
            find.bySemanticsLabel('Soundboard').evaluate().where((e) {
              final node = tester.getSemantics(
                find.byElementPredicate((x) => x == e),
              );
              return node.getSemanticsData().flagsCollection.namesRoute;
            }).isNotEmpty,
        isTrue,
        reason: 'a screen reader hears the phone sheet named',
      );
      semantics.dispose();
    });
  }

  testWidgets('Tab reaches a tile and Enter plays it', (tester) async {
    final wire = _Wire();
    await _pump(tester, wire);
    await _open(tester);

    bool focusedOnFirst() {
      final focused = FocusManager.instance.primaryFocus?.context;
      return focused != null &&
          find
              .descendant(
                of: _tile('clip-1'),
                matching: find.byElementPredicate((e) => e == focused),
              )
              .evaluate()
              .isNotEmpty;
    }

    for (var i = 0; i < 6 && !focusedOnFirst(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusedOnFirst(), isTrue, reason: 'Tab reaches the first tile');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitUntil(tester, () => wire.plays.isNotEmpty);
    expect(wire.plays, ['/channels/c1/voice/soundboard/clip-1/play']);

    await pumpFrames(tester);
    expect(focusedOnFirst(), isTrue, reason: 'the rest keeps the focus');
    await tester.pump(soundboardPlayCooldown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitUntil(tester, () => wire.plays.length == 2);
    expect(wire.plays.last, '/channels/c1/voice/soundboard/clip-1/play');
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
    expect(_dimmed(tester, 'clip-2'), isTrue, reason: 'resting looks disabled');
    expect(
      tester.getSemantics(find.bySemanticsLabel('Sad trombone, 3.2 s')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );

    await tester.pump(const Duration(seconds: 3));
    expect(_dimmed(tester, 'clip-2'), isFalse);
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
