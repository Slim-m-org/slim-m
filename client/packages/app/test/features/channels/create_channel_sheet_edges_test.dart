// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything in the create channel sheet shares one left and one right edge,
/// the Private row included.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _open(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meProvider.overrideWith(
          (ref) async => const api.Me(
            id: 'user-1',
            username: 'user-1',
            displayName: 'User',
            createdAt: 0,
            permissions: Perm.manageRoles,
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCreateChannelSheet(context, initialKind: 'text'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Rect _rectOf(WidgetTester tester, Finder finder) =>
    tester.getRect(finder.first);

void main() {
  for (final width in [1100.0, 390.0]) {
    testWidgets('at $width, the sheet keeps one left and one right edge', (
      tester,
    ) async {
      await _open(tester, width);
      final field = _rectOf(
        tester,
        find.byWidgetPredicate(
          (w) => w is AppInput && w.placeholder == 'Channel name',
        ),
      );
      final button = _rectOf(
        tester,
        find.byWidgetPredicate(
          (w) => w is AppButton && w.variant == AppButtonVariant.primary,
        ),
      );
      final label = _rectOf(tester, find.text('Private'));
      final caption = _rectOf(
        tester,
        find.textContaining('People post messages'),
      );
      final toggle = _rectOf(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w is AppToggle && w.semanticLabel == 'Make this channel private',
        ),
      );

      final lefts = {
        'field': field.left,
        'button': button.left,
        'caption': caption.left,
        'Private': label.left,
      };
      final rights = {
        'field': field.right,
        'button': button.right,
        'toggle': toggle.right,
      };
      expect(lefts.values.toSet(), hasLength(1), reason: '$lefts');
      expect(rights.values.toSet(), hasLength(1), reason: '$rights');
    });
  }
}
