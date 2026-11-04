// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The create-channel dialog, the category menu and rename sheet, a voice
/// row's menu and a select row inside a dialog, at desktop and phone width.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// no overflow.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/features/channels/widgets/manage_category_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

const _sizes = {'desktop': Size(1100, 760), 'phone': Size(390, 760)};

const _category = ChannelCategoryRow(id: 'cat1', name: 'Lounge', position: 0);

const _voice = Channel(
  id: 'v1',
  name: 'Game night',
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: 'cat1',
  roomOwnerId: 'self',
);

Future<void> _mount(WidgetTester tester, String size, Widget home) async {
  tester.view.physicalSize = _sizes[size]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meProvider.overrideWith(
          (ref) async => const api.Me(
            id: 'self',
            username: 'self',
            displayName: 'Self',
            createdAt: 0,
            permissions: 0x7fffffff,
          ),
        ),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'self',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 0,
            ),
          ),
        ),
      ],
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(body: home),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// A route needs a frame to start its animation before a long pump can finish it.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1500));
}

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 1500));
  await expectSettled(tester, name, allowNoText: true);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

Widget _rail(List<Channel> channels) => ChannelCategorySections(
  channels: channels,
  categories: const [_category],
  selectedId: null,
  canManage: true,
  onReorder: (_) {},
);

Widget _opener(String label, Future<void> Function(BuildContext) open) =>
    Builder(
      builder: (context) => TextButton(
        key: const Key('open'),
        onPressed: () => open(context),
        child: Text(label),
      ),
    );

Future<void> _rightClick(WidgetTester tester, String text) async {
  await tester.tapAt(
    tester.getCenter(find.text(text)),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadRealFonts);

  for (final size in _sizes.keys) {
    testWidgets('create channel dialog $size', (tester) async {
      await _mount(
        tester,
        size,
        _opener('open', (c) => showCreateChannelSheet(c, initialKind: 'text')),
      );
      await tester.tap(find.byKey(const Key('open')));
      await _settle(tester);
      await _shoot(tester, 'channels-create-$size');
    });

    testWidgets('category menu $size', (tester) async {
      await _mount(tester, size, _rail([_voice]));
      await tester.pump(const Duration(milliseconds: 300));
      await _rightClick(tester, 'Lounge');
      await _shoot(tester, 'channels-category-menu-$size');
    });

    testWidgets('rename category sheet $size', (tester) async {
      await _mount(
        tester,
        size,
        _opener('open', (c) => showRenameCategorySheet(c, _category)),
      );
      await tester.tap(find.byKey(const Key('open')));
      await _settle(tester);
      await _shoot(tester, 'channels-rename-category-$size');
    });

    testWidgets('voice row menu $size', (tester) async {
      await _mount(tester, size, _rail([_voice]));
      await tester.pump(const Duration(milliseconds: 300));
      await _rightClick(tester, 'Game night');
      await _shoot(tester, 'channels-voice-row-menu-$size');
    });

    testWidgets('select row in a dialog $size', (tester) async {
      await _mount(
        tester,
        size,
        _opener(
          'open',
          (c) => showAppSheet<void>(
            c,
            builder: (_) => Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: SettingsSelectRow<int>(
                label: 'Poll length',
                value: 24,
                choices: const [
                  SettingsChoice(value: 1, label: '1 hour'),
                  SettingsChoice(value: 24, label: '1 day'),
                  SettingsChoice(value: 72, label: '3 days'),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await _settle(tester);
      await tester.tap(find.text('1 day'));
      await _settle(tester);
      await _shoot(tester, 'channels-select-row-$size');
    });
  }
}
