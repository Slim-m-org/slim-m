// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The jump-to-latest arrow sits over the message column, not the window: it
/// is centred on the column and above the composer beside a docked member
/// pane on a small desktop window, and beside a docked thread.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/channels/providers/threads.dart'
    show dockedThreadsProvider;
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

final _backlog = [
  for (var seq = 1; seq <= 40; seq++)
    api.Message(
      id: 'm-$seq',
      channelId: 'c-general',
      authorId: seq.isEven ? 'user-nick' : 'user-ada',
      authorDisplayName: seq.isEven ? 'Nick' : 'Ada Lovelace',
      seq: seq,
      content: 'Backlog line $seq.',
      createdAt: 1753600000000 + seq * 600000,
      editedAt: null,
    ),
];

/// The channel's own transcript; a docked thread's is the second.
final _transcript = find.byWidgetPredicate((w) => w is MessageTranscript).first;
final _arrow = find.byKey(const Key('jump-to-latest-tap-target'));
final _composerHint = find.text('Message #general');

/// With the member pane docked, its default.
Future<void> _check(
  WidgetTester tester, {
  required double width,
  bool thread = false,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(
    messages: _backlog,
    extraOverrides: [
      if (thread)
        dockedThreadsProvider.overrideWith((ref) => {'c-general': 'c-thread'}),
    ],
  );
  await withFixtureTeardown(tester, fixture, () async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: fixtureRouter('/channels/c-general'),
          builder: appChromeBuilder,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    final list = find
        .descendant(
          of: _transcript,
          matching: find.byWidgetPredicate((w) => w is Scrollable),
        )
        .first;
    // Away into history, then a little back toward the newest, which is what arms the arrow.
    await tester.drag(list, const Offset(0, 700));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.drag(list, const Offset(0, -120));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 350));
    }

    final column = tester.getRect(_transcript);
    final arrow = tester.getRect(_arrow);
    final composer = tester.getRect(_composerHint.first);
    expect(arrow.center.dx, moreOrLessEquals(column.center.dx, epsilon: 0.5));
    expect(arrow.left, greaterThanOrEqualTo(column.left));
    expect(arrow.right, lessThanOrEqualTo(column.right));
    expect(arrow.bottom, lessThanOrEqualTo(composer.top));
    expect(arrow.top, greaterThanOrEqualTo(column.top));
    expect(column.right, lessThanOrEqualTo(width));
  });
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('beside the member pane at 836 the arrow is over the column', (
    tester,
  ) async {
    await _check(tester, width: 836);
  });

  testWidgets('beside a docked thread the arrow is over the column', (
    tester,
  ) async {
    await _check(tester, width: 1366, thread: true);
  });
}
