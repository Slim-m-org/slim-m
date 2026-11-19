// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: clicking a voice channel still joins it, and its menu's "View
/// details" opens the channel's calls without joining, with Join muted first
/// and a plain Join beside it. In the call it opens the call's details instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/call_details_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/call_details_fixture.dart';
import '../../support/geometry.dart';
import '../../support/menu_gestures.dart';

Future<void> _viewDetails(WidgetTester tester, double width) async {
  final row = find.text('hangout').first;
  await (width < 600
      ? longPressMenu(tester, row)
      : rightClickMenu(tester, row));
  await tester.tap(find.text('View details'));
  await pumpFrames(tester, frames: 20);
}

Finder _button(String label) => find.widgetWithText(AppButton, label);

void main() {
  for (final width in [390.0, 1280.0, 1920.0]) {
    testWidgets('View details shows the calls without joining at $width', (
      tester,
    ) async {
      final s = await pumpCallDetailsShell(
        tester,
        width: width,
        height: width < 600 ? 844 : 900,
        inCall: false,
        location: '/channels',
      );

      await _viewDetails(tester, width);

      expect(s.location, '/channels/$detailsVoiceId?details=1');
      expect(s.tokenRequests, isEmpty, reason: 'looking never joins');
      expect(s.container.read(voiceFlagsProvider).channelId, isNull);
      expect(find.text('This call'), findsOneWidget);
      expect(find.text('Earlier in #hangout'), findsOneWidget);
      final muted = tester.widget<AppButton>(_button('Join muted'));
      final plain = tester.widget<AppButton>(_button('Join'));
      expect(muted.variant, AppButtonVariant.primary);
      expect(plain.variant, AppButtonVariant.secondary);
      final mutedRect = tester.getRect(_button('Join muted'));
      final plainRect = tester.getRect(_button('Join'));
      expect(mutedRect.top, plainRect.top, reason: 'one row of buttons');
      expect(plainRect.right, lessThan(mutedRect.left), reason: 'muted last');
      for (final edge in GeometryEdge.values) {
        expectClearOfEdge(tester, _button('Join muted'), edge, minimum: 16);
        expectClearOfEdge(tester, _button('Join'), edge, minimum: 16);
      }
      expect(
        tester.getRect(find.text('This call')).top,
        greaterThan(mutedRect.bottom),
        reason: 'the join bar leads the page',
      );
      if (width >= 600) {
        expect(
          tester.getRect(find.text('last call yesterday')).top,
          closeTo(AppSizes.headerBar + AppSpacing.s24 + AppSpacing.s16, 1),
          reason: 'the page starts under the header, never centred in it',
        );
      }
      await s.dispose(tester);
    });
  }

  testWidgets('tapping the row after viewing its details joins once', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      inCall: false,
      location: '/channels',
    );
    await _viewDetails(tester, 1280);

    await tester.tap(find.text('hangout').first);
    await pumpFrames(tester, frames: 20);

    expect(s.location, '/channels/$detailsVoiceId');
    expect(s.tokenRequests, hasLength(1));
    await s.dispose(tester);
  });

  testWidgets('View details in the call docks the call details', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      location: '/channels',
    );
    await _viewDetails(tester, 1280);

    expect(find.byKey(callDetailsPanelKey), findsOneWidget);
    expect(s.tokenRequests, isEmpty);
    await s.dispose(tester);
  });
}
