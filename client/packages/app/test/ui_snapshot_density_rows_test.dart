// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Search hits and a thread (its parent card over the replies) at Default and
/// Compact density, at a phone and a desktop width. PNGs are written only
/// under SLIMM_UI_SNAPSHOTS=1; otherwise each scene asserts it lays out
/// cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/display_density.dart';
import 'package:slimm_app/src/widgets/channel_search.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/thread_parent_card.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'ui_snapshot_support.dart';

const _lines = [
  ('Priya', 'morning, did anyone look at the canvas bug'),
  ('Marco', 'yes, it was the seq ordering on resync'),
  ('Priya', 'thanks, merging after ci'),
];

Widget _reply(int i) => MessageRow(
  message: message(
    id: 'r$i',
    authorId: _lines[i].$1,
    authorDisplayName: _lines[i].$1,
    content: _lines[i].$2,
  ),
  grouped: false,
  showNewDivider: false,
  knownUsernames: const {},
  actions: noActions,
  editing: false,
  callbacks: MessageRowCallbacks(
    onRetry: noop,
    onDiscard: noop,
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: (_) {},
    onCancelEdit: noop,
  ),
);

List<Widget> _scene(String scene) => scene == 'search'
    ? [
        for (var i = 0; i < _lines.length; i++)
          SearchResultRow(
            message: api.Message(
              id: 's$i',
              channelId: 'c1',
              authorId: _lines[i].$1,
              authorDisplayName: _lines[i].$1,
              seq: i,
              content: _lines[i].$2,
              createdAt: 0,
              editedAt: null,
            ),
            knownUsernames: const {},
            customEmoji: const {},
            onSelect: (_) {},
          ),
      ]
    : [
        const ThreadParentCard(
          parent: api.ThreadParent(
            parentChannelId: 'c1',
            parentMessageId: 'm0',
            parentContent: 'the canvas bug: strokes land out of order',
            parentAuthorId: 'Priya',
            parentAuthorDisplayName: 'Priya',
          ),
          threadChannelId: 't1',
        ),
        for (var i = 0; i < _lines.length; i++) _reply(i),
      ];

void main() {
  setUpAll(() async {
    await loadRealFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in const [390.0, 1280.0]) {
    for (final scene in const ['search', 'thread']) {
      for (final density in const [AppDensity.normal, AppDensity.compact]) {
        final name = '$scene-${width.toInt()}-${density.name}';
        testWidgets(name, (tester) async {
          tester.view.physicalSize = Size(width, 600);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          await container
              .read(messageDensityControllerProvider.notifier)
              .select(density);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildTheme(Brightness.dark, AppTokens.dark),
                  home: Scaffold(
                    body: ListView(
                      padding: scene == 'search'
                          ? const EdgeInsets.all(AppSpacing.s16)
                          : EdgeInsets.zero,
                      children: _scene(scene),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await writeSnapshot(tester, 'density-rows-$name');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
