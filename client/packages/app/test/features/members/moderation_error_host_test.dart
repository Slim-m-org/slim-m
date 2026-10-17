// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refused moderation write is shown wherever the moderator is, not only in
/// the member pane.
///
/// Row menus and the profile popover close before their request answers, and
/// on a phone the pane lives in a closed end drawer, so a refused eject from
/// the call screen used to change nothing on screen and surface, stale, the
/// next time the drawer opened. The routed screen here has no member pane at
/// all, which is the case that went wrong.
///
/// A band above the app, not an overlay: it must not cover the screen under
/// it, and must not remount the routed app when it appears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/members/providers/member_moderation_error.dart';
import 'package:slimm_design_system/design_system.dart';

class _Screen extends StatefulWidget {
  const _Screen();

  static int mounts = 0;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  @override
  void initState() {
    super.initState();
    _Screen.mounts++;
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('the call screen')));
}

Future<ProviderContainer> _pump(WidgetTester tester, Size size) async {
  _Screen.mounts = 0;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        builder: appChromeBuilder,
        home: const _Screen(),
      ),
    ),
  );
  return container;
}

void main() {
  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1280, 800)),
  ]) {
    testWidgets('a refused write is visible on screen at $name width with no '
        'member pane mounted, and dismissing clears it', (tester) async {
      final container = await _pump(tester, size);
      expect(find.byType(AppErrorState), findsNothing);

      container.read(memberModerationErrorProvider.notifier).state =
          'Could not eject maya from the call: you do not have permission.';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AppErrorState), findsOneWidget);
      final box = tester.getRect(find.byType(AppErrorState));
      final screen = Offset.zero & size;
      expect(
        screen.contains(box.topLeft) && screen.contains(box.bottomRight),
        isTrue,
        reason: 'fully on screen, not clipped or off the edge: $box',
      );
      expect(box.top, lessThan(AppSpacing.s16 + 1));
      expect(box.height, lessThan(size.height / 3));
      expect(
        tester.getRect(find.byType(Scaffold)).top,
        greaterThanOrEqualTo(box.bottom),
        reason: 'the band pushes the app down instead of covering it',
      );
      expect(_Screen.mounts, 1, reason: 'the routed app must not remount');

      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(container.read(memberModerationErrorProvider), isNull);
      expect(find.byType(AppErrorState), findsNothing);
      expect(_Screen.mounts, 1);
    });
  }
}
