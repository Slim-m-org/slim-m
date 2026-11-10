// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Staged emoji and typed names are not lost to an accidental dismiss: Escape,
/// a click outside, the system back and a phone's drag down each ask first,
/// and only a deliberate Discard closes the dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/emoji_add_dialog.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'emoji_add_harness.dart' show emojiPick;

const _desktop = Size(1280, 800);
const _phone = Size(390, 844);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(
  WidgetTester tester,
  Size size, {
  required bool staged,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      customEmojiProvider.overrideWith((ref) async => <api.CustomEmoji>[]),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showEmojiAddDialog(
                context,
                initial: staged
                    ? [emojiPick('aaa.png'), emojiPick('bbb.png')]
                    : const [],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _frames(tester);
}

Finder get _asked => find.text('Discard these emoji?');

Finder get _stillOpen => find.text('Create 2 emoji');

Finder get _nameField => find.byKey(const ValueKey('emoji-name-aaa.png'));

Future<void> _renameFirst(WidgetTester tester) async {
  await tester.enterText(_nameField, 'renamed');
  await tester.pump();
}

void _expectKept(WidgetTester tester) {
  expect(_stillOpen, findsOneWidget);
  expect(
    tester.widget<AppInput>(_nameField).controller!.text,
    'renamed',
    reason: 'the typed name survives',
  );
}

void main() {
  for (final size in const [_desktop, _phone]) {
    final width = size.width.toInt();

    testWidgets('Escape asks before dropping staged emoji at $width', (
      tester,
    ) async {
      await _open(tester, size, staged: true);
      await _renameFirst(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(_asked, findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await _frames(tester);
      expect(_asked, findsNothing);
      _expectKept(tester);
    });

    testWidgets('the system back asks before dropping staged emoji at $width', (
      tester,
    ) async {
      await _open(tester, size, staged: true);
      await _renameFirst(tester);

      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(_asked, findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await _frames(tester);
      _expectKept(tester);
    });

    testWidgets('a click outside asks before dropping staged emoji at $width', (
      tester,
    ) async {
      await _open(tester, size, staged: true);
      await _renameFirst(tester);

      await tester.tapAt(Offset(size.width - 4, 12));
      await _frames(tester);
      expect(_asked, findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await _frames(tester);
      _expectKept(tester);
    });

    testWidgets('Close asks, and Discard closes it at $width', (tester) async {
      await _open(tester, size, staged: true);

      await tester.tap(find.bySemanticsLabel('Close'));
      await _frames(tester);
      expect(_asked, findsOneWidget);

      await tester.tap(find.text('Discard'));
      await _frames(tester);
      expect(_stillOpen, findsNothing);
      expect(_asked, findsNothing);
    });

    testWidgets('with nothing staged Escape closes at once at $width', (
      tester,
    ) async {
      await _open(tester, size, staged: false);
      expect(find.text('Choose files'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);

      expect(find.text('Choose files'), findsNothing);
      expect(_asked, findsNothing);
    });
  }

  testWidgets('dragging the phone sheet down does not drop staged emoji', (
    tester,
  ) async {
    await _open(tester, _phone, staged: true);
    await _renameFirst(tester);

    await tester.fling(find.text('Create emoji'), const Offset(0, 600), 2000);
    await _frames(tester);

    _expectKept(tester);
  });
}
