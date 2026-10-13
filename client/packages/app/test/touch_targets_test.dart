// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's per-row controls at both densities.
///
/// Originally written for the create-channel affordance: it was rendered,
/// permitted and functional at 30x30 on a phone, which is under the 44pt
/// platform minimum, and the owner could not find it. That affordance moved
/// into the rail menus (backlog item 55),
/// which are full-width `AppMenuItem` rows rather than a bare icon button, so
/// their sizing is the design system's own `AppMenuItem` concern and is
/// covered generically in `design_system/test/touch_targets_test.dart`
/// instead of duplicated here. This file keeps the general property for
/// whatever *is* still a bare icon here - today, the per-row manage kebab.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1400, 900);

Channel _channel(String id, String name) => Channel(
  id: id,
  name: name,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Future<void> _pumpRail(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: [_channel('c1', 'general'), _channel('c2', 'random')],
            categories: const [],
            selectedId: 'c1',
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      ),
    ),
  );
}

Iterable<Size> _sizesOf(WidgetTester tester, Finder finder) =>
    finder.evaluate().map((e) => tester.getSize(find.byWidget(e.widget)));

void main() {
  testWidgets('every rail control meets 44pt at compact width', (tester) async {
    await _pumpRail(tester, _phone);

    for (final size in _sizesOf(tester, find.byType(AppIconButton))) {
      expect(size.shortestSide, greaterThanOrEqualTo(AppSizes.rowTouch));
    }
    for (final size in _sizesOf(tester, find.byType(AppListRow))) {
      expect(size.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    }
    // Only the section's add glyph: a phone row has no kebab. Proof the loops
    // above had something to walk rather than passing vacuously.
    expect(find.byType(AppIconButton), findsNWidgets(1));
    expect(find.byType(AppListRow), findsNWidgets(2));
  });

  testWidgets('no rail control grows when expanded', (tester) async {
    await _pumpRail(tester, _desktop);

    // The same proof the compact test above keeps: a loop over nothing passes.
    expect(find.byType(AppIconButton), findsNWidgets(3));
    expect(find.byType(AppListRow), findsNWidgets(2));

    for (final size in _sizesOf(tester, find.byType(AppIconButton))) {
      expect(size.shortestSide, AppSizes.rowPointer);
    }
    for (final size in _sizesOf(tester, find.byType(AppListRow))) {
      expect(size.height, AppSizes.rowPointer);
    }
  });
}
