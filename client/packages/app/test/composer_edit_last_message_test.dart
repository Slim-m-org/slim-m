// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Up in an empty composer opens the caller's own last message in the
/// channel for inline editing - the Discord/Slack muscle-memory move. See
/// `message_actions.dart`'s `lastOwnMessageInChannel`.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_editing.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_data/data.dart';

import 'composer_harness.dart';

api.Message _message(String id, String authorId, int seq) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: authorId,
  authorDisplayName: authorId,
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 1000,
  editedAt: null,
);

const _me = api.Me(
  id: 'bob',
  username: 'bob',
  displayName: 'Bob',
  createdAt: 0,
  permissions: 0,
);

void main() {
  late TextEditingController controller;
  late Sends sends;
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  List<Override> overridesFor(MessageStore store) => [
    storeProvider.overrideWith((ref) async => store),
    meProvider.overrideWith((ref) async => _me),
  ];

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Composer)));

  /// `editingMessageIdProvider` is `autoDispose`: in the real app the
  /// transcript's own row always watches it, which is what keeps a value
  /// this widget writes from being torn down again before anything reads
  /// it. Nothing here renders a transcript, so this stands in for that
  /// watcher - composer_harness.dart's own `extra` slot exists for exactly
  /// this, a sibling in the same `ProviderScope` with nothing to show.
  Widget watchEditing(String channelId) => Consumer(
    builder: (context, ref, _) {
      ref.watch(editingMessageIdProvider(channelId));
      return const SizedBox.shrink();
    },
  );

  /// A working `storeProvider` override means the composer's own slow-mode
  /// watch opens a real drift stream on the channel row; unmounting deliberately,
  /// with a few more pumps, gives its zero-duration cleanup timer the turn it
  /// needs before flutter_test's own "no pending timers" check runs - the
  /// same fix `channel_screen_test.dart` uses for the same reason.
  Future<void> unmountAndFlush(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  testWidgets(
    'Up in an empty composer opens the caller\'s own last message for '
    'editing',
    (tester) async {
      await store.applyMessages([
        _message('m1', 'alice', 1),
        _message('m2', 'bob', 2),
        _message('m3', 'alice', 3),
        _message('m4', 'bob', 4),
      ]);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          extraOverrides: overridesFor(store),
          extra: watchEditing('c1'),
        ),
      );
      final container = containerOf(tester);

      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(container.read(editingMessageIdProvider('c1')), 'm4');
      await unmountAndFlush(tester);
    },
  );

  testWidgets('Up with text already typed moves the caret and edits nothing', (
    tester,
  ) async {
    await store.applyMessages([_message('m1', 'bob', 1)]);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        extraOverrides: overridesFor(store),
        extra: watchEditing('c1'),
      ),
    );
    final container = containerOf(tester);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'still drafting');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(controller.text, 'still drafting');
    expect(container.read(editingMessageIdProvider('c1')), isNull);
    await unmountAndFlush(tester);
  });

  testWidgets(
    'Up in an empty composer does nothing when the caller has no message '
    'in this channel',
    (tester) async {
      await store.applyMessages([_message('m1', 'alice', 1)]);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          extraOverrides: overridesFor(store),
          extra: watchEditing('c1'),
        ),
      );
      final container = containerOf(tester);

      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(container.read(editingMessageIdProvider('c1')), isNull);
      await unmountAndFlush(tester);
    },
  );
}
