// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `editingMessageIdProvider`'s own doc comment claims two things: it is
/// `family`-keyed so an edit started in one channel cannot keep showing
/// after a switch to another, and `autoDispose` so a channel nobody is
/// looking at does not keep carrying stale edit state indefinitely. Neither
/// claim had a test; `message_transcript_rebuild_test.dart` only proves the
/// unrelated rebuild-count property this provider was built for.
///
/// Driven directly against the provider through a bare `Consumer`, not a
/// full `ChannelScreen`: the risk under test is Riverpod's own
/// `autoDispose.family` mechanics, which do not need a transcript, a store
/// or a router to exercise honestly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_editing.dart';

/// Watches [channelId]'s own answer for message `m1` and renders it as plain
/// text, so the test can assert on what is on screen rather than reaching
/// back into the provider itself - the same "watch it the way a row would"
/// discipline `MessageRowExtras` itself follows.
Widget _watcher(String channelId) => Directionality(
  textDirection: TextDirection.ltr,
  child: Consumer(
    builder: (context, ref, _) {
      final editing = ref.watch(
        editingMessageIdProvider(channelId).select((id) => id == 'm1'),
      );
      return Text(editing ? 'editing' : 'not editing');
    },
  ),
);

void main() {
  testWidgets(
    'an edit started in one channel does not reappear after switching away '
    'and back',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: _watcher('A')),
      );
      container.read(editingMessageIdProvider('A').notifier).state = 'm1';
      await tester.pump();
      expect(find.text('editing'), findsOneWidget);

      // The switch itself: channel A's own watcher is gone, replaced by channel B's, the same swap `MessageTranscript` makes across a channel switch.
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: _watcher('B')),
      );
      // Lets the now-unwatched autoDispose provider actually dispose.
      await tester.pump();
      await tester.pump();

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: _watcher('A')),
      );
      await tester.pump();

      expect(
        find.text('editing'),
        findsNothing,
        reason:
            'reproduction target: switching back to A must find a fresh '
            'provider, not the one still holding m1 from before the switch',
      );
    },
  );

  testWidgets('two different channels never see each other\'s edit', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [_watcher('A'), _watcher('B')]),
        ),
      ),
    );

    container.read(editingMessageIdProvider('A').notifier).state = 'm1';
    await tester.pump();

    expect(find.text('editing'), findsOneWidget);
    expect(find.text('not editing'), findsOneWidget);
  });
}
