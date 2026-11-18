// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard grid when a long name wraps: every tile in its row is as
/// tall as the row, and a list that scrolls still shows half of a sixth row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/soundboard_clips.dart';
import 'package:slimm_app/src/features/voice/widgets/soundboard_picker.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

const _long = 'a long clip name';

api.SoundClip _clip(int i, {bool long = false}) => api.SoundClip(
  id: 'c$i',
  name: long ? _long : 'Clip$i',
  durationMs: 1000,
  uploaderId: null,
  createdAt: i,
);

Future<void> _pump(WidgetTester tester, List<api.SoundClip> clips) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [soundClipsProvider.overrideWith((ref) async => clips)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: soundboardMenuWidth,
              child: SoundboardPicker(channelId: 'c1'),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

Rect _tile(WidgetTester tester, int i) =>
    tester.getRect(find.byKey(ValueKey('c$i')));

void main() {
  testWidgets('a wrapped name makes its whole row taller, not one tile', (
    tester,
  ) async {
    await _pump(tester, [_clip(0), _clip(1, long: true), _clip(2)]);

    final tall = _tile(tester, 1);
    for (final i in [0, 2]) {
      expect(_tile(tester, i).top, tall.top, reason: 'one row');
      expect(_tile(tester, i).height, tall.height, reason: 'row height');
    }
  });

  testWidgets('wrapped rows still leave half a sixth row showing', (
    tester,
  ) async {
    await _pump(tester, [
      for (var i = 0; i < 24; i++) _clip(i, long: i % 3 == 0 && i < 15),
    ]);

    final viewport = tester.getRect(
      find.byWidgetPredicate((w) => w is Scrollable),
    );
    final sixth = _tile(tester, 15);
    expect(_tile(tester, 0).height, greaterThan(sixth.height));
    expect(viewport.top, _tile(tester, 0).top);
    expect(
      viewport.bottom,
      moreOrLessEquals(sixth.top + sixth.height / 2, epsilon: 1),
    );
  });
}
