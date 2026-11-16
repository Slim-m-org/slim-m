// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji picker opens on one surface per width class wherever it is
/// reached from: anchored beside what opened it on a pointer width, and on
/// compact a bottom sheet from a message, or inline under a field that
/// already sits in a sheet. It never stacks a second modal.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sheet.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

void _noop() {}

const _actions = MessageActions(
  canReply: true,
  onReply: _noop,
  canEdit: false,
  onEdit: _noop,
  canDelete: false,
  onDelete: _noop,
  canManagePins: false,
  pinned: false,
  onTogglePin: _noop,
  canReport: false,
  onReport: _noop,
  canBlockAuthor: false,
  onBlockAuthor: _noop,
  canOpenThread: false,
  onOpenThread: _noop,
  canCopyLink: false,
  onCopyLink: _noop,
  canForward: false,
  onForward: _noop,
  canSave: false,
  onSave: _noop,
);

final _panel = find.byWidgetPredicate((w) => w is EmojiPickerPanel);
final _barriers = find.byWidgetPredicate((w) => w is ModalBarrier);

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [customEmojiProvider.overrideWith((ref) async => const [])],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: home),
      ),
    ),
  );
  await pumpFrames(tester);
}

Widget _opener(void Function(BuildContext context) open) => Builder(
  builder: (context) =>
      TextButton(onPressed: () => open(context), child: const Text('open')),
);

Future<void> _openMessageMenu(
  WidgetTester tester, {
  required bool touch,
}) async {
  final at = tester.getTopLeft(find.text('hello')) + const Offset(4, 4);
  if (touch) {
    await tester.longPressAt(at);
  } else {
    await tester.tapAt(
      at,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await pumpFrames(tester, frames: 30);
}

const _message = MessageContextMenuRegion(
  content: 'hello',
  actions: _actions,
  onPickReaction: _ignore,
  child: SizedBox(width: 400, height: 120, child: Text('hello')),
);

void _ignore(String _) {}

void main() {
  testWidgets('a pointer width opens Add reaction from the menu beside it', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 900), _message);
    final barriers = _barriers.evaluate().length;
    await _openMessageMenu(tester, touch: false);

    await tester.tap(find.bySemanticsLabel(ActionLabels.addReaction));
    await pumpFrames(tester, frames: 30);

    expect(_panel, findsOneWidget);
    expect(_barriers, findsNWidgets(barriers), reason: 'no modal route');
    final pointer = tester.getTopLeft(find.text('hello'));
    expect(
      (tester.getTopLeft(_panel) - pointer).distance,
      lessThan(64),
      reason: 'anchored where the menu was, not centred in the window',
    );
  });

  testWidgets('a compact width opens Add reaction as a bottom sheet', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 844), _message);
    await _openMessageMenu(tester, touch: true);

    await tester.tap(find.bySemanticsLabel(ActionLabels.addReaction));
    await pumpFrames(tester, frames: 30);

    expect(_panel, findsOneWidget);
    expect(
      tester.getBottomLeft(_panel).dy,
      greaterThan(844 / 2),
      reason: 'a sheet rises from the bottom',
    );
  });

  for (final size in const [Size(1280, 900), Size(390, 844)]) {
    final width = size.width.toInt();

    testWidgets('the poll composer picks an emoji without a second modal at '
        '$width', (tester) async {
      await _pump(
        tester,
        size,
        _opener((context) => showPollComposerSheet(context, 'c1')),
      );
      await tester.tap(find.text('open'));
      await pumpFrames(tester, frames: 30);
      final barriers = _barriers.evaluate().length;

      await tester.tap(find.bySemanticsLabel('Insert emoji in the question'));
      await pumpFrames(tester, frames: 30);

      expect(_panel, findsOneWidget);
      expect(_barriers, findsNWidgets(barriers));
    });

    testWidgets('a canvas note picks an emoji without a second modal at '
        '$width', (tester) async {
      await _pump(
        tester,
        size,
        _opener((context) => showCanvasNoteSheet(context)),
      );
      await tester.tap(find.text('open'));
      await pumpFrames(tester, frames: 30);
      final barriers = _barriers.evaluate().length;

      await tester.tap(find.bySemanticsLabel('Insert emoji'));
      await pumpFrames(tester, frames: 30);

      expect(_panel, findsOneWidget);
      expect(_barriers, findsNWidgets(barriers));
    });
  }
}
