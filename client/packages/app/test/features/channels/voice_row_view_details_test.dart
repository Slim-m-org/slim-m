// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: clicking a voice channel still joins it, and its menu's "View
/// details" opens the channel's calls without joining, with Join muted first
/// and a plain Join beside it. In the call it opens the call's details instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/call_details_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/call_details_fixture.dart';
import '../../support/geometry.dart';
import '../../support/menu_gestures.dart';

Future<void> _pickFromMenu(
  WidgetTester tester,
  double width,
  String item,
) async {
  final row = find.text('hangout').first;
  await (width < 600
      ? longPressMenu(tester, row)
      : rightClickMenu(tester, row));
  await tester.tap(find.text(item));
  await pumpFrames(tester, frames: 20);
}

Future<void> _viewDetails(WidgetTester tester, double width) =>
    _pickFromMenu(tester, width, 'View details');

final _switchPrompt = find.text('Already in a call');

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

  for (final width in [390.0, 1280.0]) {
    testWidgets('in another call, View details shows the calls and keeps '
        'that call at $width', (tester) async {
      final s = await pumpCallDetailsShell(
        tester,
        width: width,
        height: width < 600 ? 844 : 900,
        callId: otherVoiceId,
        location: '/channels',
      );

      await _viewDetails(tester, width);

      expect(s.location, '/channels/$detailsVoiceId?details=1');
      expect(_switchPrompt, findsNothing, reason: 'looking is not switching');
      expect(find.text('Earlier in #hangout'), findsOneWidget);
      expect(_button('Join muted'), findsOneWidget);
      expect(s.tokenRequests, isEmpty);
      expect(s.container.read(voiceFlagsProvider).channelId, otherVoiceId);
      await s.dispose(tester);
    });
  }

  testWidgets('in another call, Open chat reads it without the switch prompt', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      callId: otherVoiceId,
      location: '/channels',
    );

    await _pickFromMenu(tester, 1280, 'Open chat');

    expect(s.location, '/channels/$detailsVoiceId?chat=1');
    expect(_switchPrompt, findsNothing);
    expect(
      tester.getRect(_button('Join muted')).top,
      greaterThan(tester.getRect(find.text(voiceRosterUnknownLine)).bottom),
      reason: 'beside the docked chat the buttons take their own row',
    );
    expect(s.tokenRequests, isEmpty);
    expect(s.container.read(voiceFlagsProvider).channelId, otherVoiceId);
    await s.dispose(tester);
  });

  testWidgets('in another call, Join on the details asks before switching', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      callId: otherVoiceId,
      location: '/channels',
    );
    await _viewDetails(tester, 1280);

    await tester.tap(_button('Join muted'));
    await pumpFrames(tester, frames: 20);
    expect(_switchPrompt, findsOneWidget);
    expect(s.tokenRequests, isEmpty, reason: 'nothing leaves until confirmed');

    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester, frames: 20);
    expect(_switchPrompt, findsNothing);
    expect(find.text('Earlier in #hangout'), findsOneWidget);
    expect(s.tokenRequests, isEmpty);

    await tester.tap(_button('Join muted'));
    await pumpFrames(tester, frames: 20);
    await tester.tap(find.text('Switch to this call'));
    await pumpFrames(tester, frames: 20);
    expect(s.tokenRequests, hasLength(1));
    final controller = s.container.read(voiceControllerProvider.notifier);
    expect(controller.lastJoinMuted, isTrue, reason: 'the join that was asked');
    await s.dispose(tester);
  });

  testWidgets('in another call, a second tap on the row still asks first', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      callId: otherVoiceId,
      location: '/channels',
    );

    for (var tap = 0; tap < 2; tap++) {
      await tester.tap(find.text('hangout').first);
      await pumpFrames(tester, frames: 20);
      expect(_switchPrompt, findsOneWidget, reason: 'tap ${tap + 1}');
    }
    expect(s.tokenRequests, isEmpty, reason: 'nothing leaves until confirmed');
    expect(s.container.read(voiceFlagsProvider).channelId, otherVoiceId);
    await s.dispose(tester);
  });

  testWidgets('View details again in the call reopens the closed details', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      location: '/channels',
    );
    await _viewDetails(tester, 1280);
    expect(find.byKey(callDetailsPanelKey), findsOneWidget);

    await tester.tap(find.byTooltip('Call details'));
    await pumpFrames(tester);
    expect(find.byKey(callDetailsPanelKey), findsNothing);

    await _viewDetails(tester, 1280);
    expect(find.byKey(callDetailsPanelKey), findsOneWidget);

    await tester.tap(find.byTooltip('Toggle text chat'));
    await pumpFrames(tester);
    expect(find.byKey(callDetailsPanelKey), findsNothing);
    await _viewDetails(tester, 1280);
    expect(find.byKey(callDetailsPanelKey), findsOneWidget);
    expect(s.tokenRequests, isEmpty);
    await s.dispose(tester);
  });
}
