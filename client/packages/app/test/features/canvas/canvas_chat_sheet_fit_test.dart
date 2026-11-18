// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas chat sheet is as tall as its chat, up to its cap: a short call
/// chat opened as a sheet of empty space above the first message (owner,
/// 2026-11-18). A long one still fills the cap, newest on the composer, and
/// neither opens at the empty chat's height and then grows to its messages.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/canvas/screens/canvas_chat_toggle.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

const _screen = Size(390, 844);

List<api.Message> _chat(int count) => [
  for (var seq = 1; seq <= count; seq++)
    api.Message(
      id: 'main-$seq',
      channelId: 'c-main',
      authorId: seq.isEven ? 'user-nick' : 'user-ada',
      authorDisplayName: seq.isEven ? 'Nick' : 'Ada Lovelace',
      seq: seq,
      content: 'Call chat line $seq.',
      createdAt: 1753600000000 + seq * 60000,
      editedAt: null,
    ),
];

Future<void> _withSheet(
  WidgetTester tester,
  int messages,
  void Function() check,
) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(messages: _chat(messages));
  await withFixtureTeardown(tester, fixture, () async {
    await _open(tester, fixture.container);
    check();
  });
}

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  _push(await _shell(tester, container));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Future<BuildContext> _shell(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
        builder: appChromeBuilder,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  return tester.element(find.textContaining('general').first);
}

void _push(BuildContext page) => unawaited(showCanvasChatSheet(page, 'c-main'));

final _chatBox = find.bySemanticsLabel('Text chat');

Rect _sheet(WidgetTester tester) => tester.getRect(_chatBox);

/// The chat's laid-out height on each frame of its entrance, while its
/// messages load from the store in real time.
Future<List<double>> _openingHeights(
  WidgetTester tester,
  Size screen,
  int messages,
) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(messages: _chat(messages));
  final heights = <double>[];
  await withFixtureTeardown(tester, fixture, () async {
    _push(await _shell(tester, fixture.container));
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (_chatBox.evaluate().isNotEmpty) {
        heights.add(tester.getSize(_chatBox).height);
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4)),
      );
    }
  });
  return heights;
}

/// Whether [heights] ever grows from one frame to the next.
Matcher get _neverGrows => predicate<List<double>>((heights) {
  for (var i = 1; i < heights.length; i++) {
    if (heights[i] > heights[i - 1] + 0.5) return false;
  }
  return heights.isNotEmpty;
}, 'a height that never grows frame to frame');

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a short call chat opens no taller than its messages', (
    tester,
  ) async {
    await _withSheet(tester, 4, () {
      final sheet = _sheet(tester);
      final start = tester.getRect(find.text('Chat for main'));
      expect(sheet.height, lessThan(_screen.height * 0.8 - 1));
      // The start header's own top padding, icon and gap, and nothing above them.
      expect(start.top - sheet.top, lessThanOrEqualTo(24 + 48 + 12 + 1));
      expect(find.text('Call chat line 4.'), findsOneWidget);
    });
  });

  testWidgets('a long call chat fills the cap, newest on the composer', (
    tester,
  ) async {
    await _withSheet(tester, 60, () {
      final sheet = _sheet(tester);
      expect(sheet.height, moreOrLessEquals(_screen.height * 0.8, epsilon: 1));
      expect(find.text('Chat for main'), findsNothing);
      final newest = tester.getRect(find.text('Call chat line 60.'));
      final composer = tester.getRect(
        find
            .descendant(
              of: find.bySemanticsLabel('Text chat'),
              matching: find.textContaining('Message'),
            )
            .last,
      );
      expect(composer.top - newest.bottom, lessThan(AppSpacing.s48));
    });
  });

  for (final (name, screen) in [
    ('sheet', _screen),
    ('dialog', const Size(700, 900)),
  ]) {
    testWidgets('the $name never opens short and then grows to its chat', (
      tester,
    ) async {
      final heights = await _openingHeights(tester, screen, 4);
      expect(heights, _neverGrows, reason: '$heights');
    });
  }
}
