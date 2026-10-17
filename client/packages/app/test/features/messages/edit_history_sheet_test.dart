// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edit-history viewer: the "(edited)" marker opens a sheet listing every
/// version the message has held, oldest first, labelled from Original to
/// Current, and a failed load says so with a retry rather than spinning.
///
/// The word-diff coverage below checks actual painted state - the `TextSpan`
/// style Flutter will use, and a greyscale ink mask of it - rather than just
/// finding text on screen, the same standard `list_row_mention_test.dart`
/// set for the rail's mention dot: colour must never be the only thing
/// telling an addition from a removal apart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/edit_history_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

List<Override> _apiOverrides(
  Future<http.Response> Function(http.Request request) handler,
) => [
  apiProvider.overrideWith((ref) {
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: MockClient(handler),
    );
    ref.onDispose(api.close);
    return api;
  }),
];

Future<void> _pumpAndOpen(
  WidgetTester tester,
  List<Override> overrides, {
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    showMessageEditHistorySheet(context, 'c1', 'm1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The history endpoint's response body for a list of `(content, atMillis)`
/// versions.
http.Response _historyResponse(List<(String, int)> versions) => http.Response(
  jsonEncode([
    for (final (content, at) in versions) {'content': content, 'at': at},
  ]),
  200,
  headers: {'content-type': 'application/json'},
);

/// Every `TextSpan` child across every `SelectableText` in the tree, in
/// paint order - the diff's actual rendered state, not a re-derivation of it.
List<TextSpan> _diffSpans(WidgetTester tester) => [
  for (final widget in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  ))
    ...?widget.textSpan?.children?.whereType<TextSpan>(),
];

/// The style of the one span whose text is exactly [text]. Fails loudly
/// rather than returning null, since a missing span means the diff shape
/// this test assumes has already changed.
TextStyle _styleOf(WidgetTester tester, String text) {
  final spans = _diffSpans(tester).where((s) => s.text == text);
  expect(
    spans,
    hasLength(1),
    reason: 'expected exactly one span with text "$text"',
  );
  return spans.single.style!;
}

/// Rec. 709 luma, matching `list_row_mention_test.dart`'s conversion.
double _luma(double r, double g, double b) =>
    0.2126 * r + 0.7152 * g + 0.0722 * b;

const double _inkThreshold = 0.15;

List<bool> _inkMask(ByteData rgba, Color surface) {
  final background = _luma(surface.r, surface.g, surface.b);
  final mask = <bool>[];
  for (var i = 0; i < rgba.lengthInBytes; i += 4) {
    final grey = _luma(
      rgba.getUint8(i) / 255,
      rgba.getUint8(i + 1) / 255,
      rgba.getUint8(i + 2) / 255,
    );
    mask.add((grey - background).abs() > _inkThreshold);
  }
  return mask;
}

int _differing(List<bool> a, List<bool> b) {
  var count = 0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) count++;
  }
  return count;
}

/// Renders one word with [style] on a fixed surface and returns its
/// greyscale ink mask, so two styles can be compared purely on the shape they
/// paint - not the colour, which desaturation below already removes.
Future<List<bool>> _inkMaskOf(WidgetTester tester, TextStyle style) async {
  const tokens = AppTokens.light;
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, tokens),
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: tokens.surfaceBase,
            child: SizedBox(
              width: 160,
              height: 40,
              child: Text.rich(TextSpan(text: 'sample', style: style)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  late List<bool> mask;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 4);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    mask = _inkMask(bytes!, tokens.surfaceBase);
  });
  return mask;
}

void main() {
  testWidgets('the marker only fires a tap when given a handler', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Column(
            children: [
              EditedMarker(onTap: () => taps++),
              const EditedMarker(),
            ],
          ),
        ),
      ),
    );

    // Same text twice in tree order: the tappable marker first, the inert one second.
    await tester.tap(find.text('edited').first);
    expect(taps, 1);
    // Tapping the handler-less marker does nothing.
    await tester.tap(find.text('edited').last);
    expect(taps, 1, reason: 'the inert marker has no tap handler');
  });

  testWidgets('the sheet lists versions oldest first, Original to Current', (
    tester,
  ) async {
    await _pumpAndOpen(
      tester,
      _apiOverrides((request) async {
        expect(request.url.path, '/channels/c1/messages/m1/history');
        return _historyResponse([
          ('alpha bravo charlie', 1000),
          ('alpha charlie', 2000),
          ('alpha charlie delta', 3000),
        ]);
      }),
    );

    expect(find.text('Edit history'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);

    // Oldest first: the original's row sits above the current's in paint order.
    final originalY = tester.getTopLeft(find.text('Original')).dy;
    final currentY = tester.getTopLeft(find.text('Current')).dy;
    expect(originalY, lessThan(currentY));
  });

  testWidgets('a single-version history reads as Current, never Original', (
    tester,
  ) async {
    // A pre-0050 edited message has one element, its current content, and must not read as "Original".
    await _pumpAndOpen(
      tester,
      _apiOverrides(
        (request) async => _historyResponse([('the only recorded text', 1000)]),
      ),
    );

    expect(find.text('the only recorded text'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Original'), findsNothing);
  });

  testWidgets('a failed load says so and offers a retry, never spins', (
    tester,
  ) async {
    await _pumpAndOpen(
      tester,
      _apiOverrides((request) async => http.Response('nope', 500)),
    );

    expect(find.text('Could not load edit history.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // The retry affordance AppAsyncView renders for a failed load.
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('retry shows a spinner while it reloads, not a frozen banner', (
    tester,
  ) async {
    var calls = 0;
    final secondLoad = Completer<http.Response>();
    await _pumpAndOpen(
      tester,
      _apiOverrides((request) async {
        calls++;
        // The first load fails; the retry hangs until this test releases it.
        return calls == 1 ? http.Response('nope', 500) : secondLoad.future;
      }),
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    // The reload shows progress, not the stale error banner.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Could not load edit history.'), findsNothing);

    secondLoad.complete(_historyResponse([('loaded on retry', 1)]));
    await tester.pumpAndSettle();
    expect(find.text('loaded on retry'), findsOneWidget);
  });

  group('one edit', () {
    testWidgets('a removed word carries strikethrough, a kept word does not - '
        'shape, not just colour, marks the change', (tester) async {
      await _pumpAndOpen(
        tester,
        _apiOverrides(
          (request) async => _historyResponse([
            ('im very sorry lol', 1000),
            ('im sorry lol', 2000),
          ]),
        ),
      );

      final removed = _styleOf(tester, 'very ');
      final kept = _styleOf(tester, 'sorry lol');
      expect(removed.decoration, TextDecoration.lineThrough);
      expect(kept.decoration, isNot(TextDecoration.lineThrough));
      expect(
        removed.color,
        isNot(kept.color),
        reason: 'colour reinforces the two states but never carries them alone',
      );
    });

    testWidgets('an added word carries underline, never a bare colour swap', (
      tester,
    ) async {
      await _pumpAndOpen(
        tester,
        _apiOverrides(
          (request) async =>
              _historyResponse([('sorry lol', 1000), ('im sorry lol', 2000)]),
        ),
      );

      final added = _styleOf(tester, 'im ');
      expect(added.decoration, TextDecoration.underline);
      expect(added.fontWeight, AppWeights.semi);
    });
  });

  group('three edits', () {
    testWidgets(
      'the two middle Edited rows are distinguishable by order, not just label',
      (tester) async {
        await _pumpAndOpen(
          tester,
          _apiOverrides(
            (request) async => _historyResponse([
              ('one two three four five', 1000),
              ('one two three four five six', 2000),
              ('one two three four five six seven', 3000),
              ('one two three four five six seven eight', 4000),
            ]),
          ),
        );

        expect(find.text('Original'), findsOneWidget);
        expect(find.text('Edited'), findsNWidgets(2));
        expect(find.text('Current'), findsOneWidget);
        expect(find.text('1 of 4'), findsOneWidget);
        expect(find.text('2 of 4'), findsOneWidget);
        expect(find.text('3 of 4'), findsOneWidget);
        expect(find.text('4 of 4'), findsOneWidget);

        // Reading order matches edit order.
        final ys = [
          tester.getTopLeft(find.text('1 of 4')).dy,
          tester.getTopLeft(find.text('2 of 4')).dy,
          tester.getTopLeft(find.text('3 of 4')).dy,
          tester.getTopLeft(find.text('4 of 4')).dy,
        ];
        expect(ys, orderedEquals(List.of(ys)..sort()));
      },
    );

    testWidgets(
      'a middle row diffs against the edit right before it, not the original',
      (tester) async {
        await _pumpAndOpen(
          tester,
          _apiOverrides(
            (request) async => _historyResponse([
              ('one two three four five', 1000),
              ('one two three four five six', 2000),
              ('one two three four five six seven', 3000),
              ('one two three four five six seven eight', 4000),
            ]),
          ),
        );

        // "3 of 4" only added "seven" over "2 of 4"; against Original it would also carry "six".
        expect(_styleOf(tester, ' seven').decoration, TextDecoration.underline);
        expect(
          _diffSpans(tester).where((s) => s.text == ' six').length,
          1,
          reason:
              '"six" is only ever added once, on the row right after it '
              'first appears - a diff against Original would add it again here',
        );
      },
    );
  });

  testWidgets('a long message still diffs the one word that changed', (
    tester,
  ) async {
    final words = List.generate(400, (i) => 'word$i');
    final oldText = words.join(' ');
    words[200] = 'CHANGED';
    final newText = words.join(' ');

    await _pumpAndOpen(
      tester,
      _apiOverrides(
        (request) async => _historyResponse([(oldText, 1000), (newText, 2000)]),
      ),
      // Tall enough that the whole scrollable history fits without scrolling to reach the diffed entry.
      size: const Size(1200, 20000),
    );
    expect(tester.takeException(), isNull);

    final removed = _diffSpans(tester).where(
      (s) =>
          s.text!.contains('word200') &&
          s.style!.decoration == TextDecoration.lineThrough,
    );
    final added = _diffSpans(tester).where(
      (s) =>
          s.text!.contains('CHANGED') &&
          s.style!.decoration == TextDecoration.underline,
    );
    expect(removed, isNotEmpty);
    expect(added, isNotEmpty);
  });

  testWidgets('collapses to a bottom sheet at phone width, still legible', (
    tester,
  ) async {
    await _pumpAndOpen(
      tester,
      _apiOverrides(
        (request) async => _historyResponse([
          ('im very sorry lol', 1000),
          ('im sorry lol', 2000),
        ]),
      ),
      size: const Size(360, 800),
    );

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(_styleOf(tester, 'very ').decoration, TextDecoration.lineThrough);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removed and added survive greyscale as different shapes, not just colours',
    (tester) async {
      await _pumpAndOpen(
        tester,
        _apiOverrides(
          (request) async => _historyResponse([
            ('alpha bravo charlie', 1000),
            ('alpha charlie delta', 2000),
          ]),
        ),
      );
      final equalStyle = _styleOf(tester, 'alpha ');
      final removedStyle = _styleOf(tester, 'bravo ');
      final addedStyle = _styleOf(tester, ' delta');

      final equalMask = await _inkMaskOf(tester, equalStyle);
      final removedMask = await _inkMaskOf(tester, removedStyle);
      final addedMask = await _inkMaskOf(tester, addedStyle);

      expect(
        _differing(removedMask, equalMask),
        greaterThan(50),
        reason: 'strikethrough must leave an ink trace once colour is gone',
      );
      expect(
        _differing(addedMask, equalMask),
        greaterThan(50),
        reason: 'underline must leave an ink trace once colour is gone',
      );
      expect(
        _differing(removedMask, addedMask),
        greaterThan(50),
        reason:
            'a removal and an addition must not paint the same '
            'silhouette - that would leave colour as the only cue again',
      );
    },
  );
}
