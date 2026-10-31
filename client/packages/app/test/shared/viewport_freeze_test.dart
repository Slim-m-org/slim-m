// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An animated image advances only while its row is inside the viewport: a
/// mounted-but-offscreen row, and every row of a shrink-wrapped short thread,
/// must hold their frame, then resume on scrolling back.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/viewport_freeze.dart';

/// Two 8x8 frames, 100ms each, looping.
final _twoFrameGif = base64Decode(
  'R0lGODlhCAAIAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAACAAIAAAIDwABCBxIsKDBgwgTKkwYEAAh+QQBCgABACwAAAAACAAIAIEAAP8AAAAAAAAAAAAIDwABCBxIsKDBgwgTKkwYEAA7',
);

const _rowHeight = 100.0;

/// The highest frame index each tagged image has been drawn at.
final _frames = <String, int>{};

Widget _gif(String tag) => ViewportFreeze(
  child: SizedBox(
    height: _rowHeight,
    child: Image.memory(
      _twoFrameGif,
      frameBuilder: (context, child, frame, sync) {
        if (frame != null) _frames[tag] = frame;
        return child;
      },
    ),
  ),
);

Widget _app({required bool shrinkWrap, required ScrollController controller}) =>
    MaterialApp(
      home: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: 150,
          child: ListView(
            controller: controller,
            shrinkWrap: shrinkWrap,
            scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
            children: [
              _gif('top'),
              const SizedBox(height: 300),
              _gif('bottom'),
            ],
          ),
        ),
      ),
    );

/// Lets decode (real async) and the frame timers (fake time) both advance.
Future<void> _tick(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _scrollTo(
  WidgetTester tester,
  ScrollController controller,
  double offset,
) async {
  controller.jumpTo(offset);
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    _frames.clear();
    // A cached completer would carry its frame timer over from the last test's clock.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  for (final shrinkWrap in [false, true]) {
    testWidgets(
      'an offscreen gif holds its frame and resumes in view (shrinkWrap: $shrinkWrap)',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _app(shrinkWrap: shrinkWrap, controller: controller),
        );
        await _tick(tester);

        expect(_frames['top'], isNotNull, reason: 'in view: first frame loads');
        expect(_frames['top'], greaterThan(0), reason: 'in view: animates');
        final held = _frames['bottom'];
        expect(held, isNotNull, reason: 'offscreen row still loads one frame');

        await _tick(tester);
        await _tick(tester);
        expect(_frames['bottom'], held, reason: 'offscreen: frame is frozen');

        await _scrollTo(tester, controller, 300);
        final before = _frames['top'];
        await _tick(tester);
        await _tick(tester);
        expect(_frames['top'], before, reason: 'scrolled away: top freezes');
      },
    );
  }

  testWidgets('a frozen gif resumes when scrolled back into view', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(shrinkWrap: false, controller: controller));
    await _tick(tester);
    await _scrollTo(tester, controller, 300);
    await _tick(tester);

    final seen = <int>{};
    for (var i = 0; i < 6; i++) {
      await _tick(tester);
      seen.add(_frames['bottom']!);
    }
    expect(seen.length, greaterThan(1), reason: 'in view again: animates');
  });
}
