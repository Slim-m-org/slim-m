// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: a voice channel's history, what happened and its transcript only
/// showed once you hung up. In the call a "Call details" toggle beside the
/// chat's now docks them beside the stage where they fit and sheets them on a
/// phone, live as the call goes on, in the one slot the chat also uses.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/voice/screens/call_details_pane.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_dock.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/call_details_fixture.dart';
import '../../support/geometry.dart';

final _panel = find.byKey(callDetailsPanelKey);
final _sheet = find.byKey(callDetailsSheetKey);
final _toggle = find.byTooltip('Call details');

Finder _inPanel(String text) =>
    find.descendant(of: _panel, matching: find.text(text));

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await pumpFrames(tester);
}

void _expectToggled(WidgetTester tester, bool on) => expect(
  tester.getSemantics(
    find.descendant(of: _toggle, matching: find.byIcon(AppIcons.activityLog)),
  ),
  isSemantics(isToggled: on, hasToggledState: true),
);

void main() {
  for (final width in [1280.0, 1920.0]) {
    testWidgets('the header toggle docks the details beside the stage at '
        '$width, and closes them again', (tester) async {
      final semantics = tester.ensureSemantics();
      final s = await pumpCallDetailsShell(tester, width: width);
      expect(_panel, findsNothing, reason: 'closed until asked for');

      await _tap(tester, _toggle);

      for (final section in [
        'This call',
        'What happened',
        'Bob started the call',
        'Transcript',
        'Can everyone see the board?',
        'Earlier in #hangout',
      ]) {
        expect(_inPanel(section), findsOneWidget, reason: section);
      }
      _expectToggled(tester, true);
      expect(_sheet, findsNothing, reason: 'docked, not a sheet');
      final panel = tester.getRect(_panel);
      expect(panel.width, kThreadPaneWidth);
      expect(
        panel.right,
        width - AppMemberPane.width,
        reason: 'between the stage and the member list',
      );
      expect(
        panel.top,
        AppSizes.headerBar,
        reason: 'straight under the header',
      );
      expectEdgeGap(tester, _panel, GeometryEdge.bottom, 0);
      expect(
        tester.getRect(find.byKey(VoiceCallDock.slideKey)).right,
        lessThanOrEqualTo(panel.left),
        reason: 'the call controls stay on the stage, clear of the panel',
      );

      await _tap(tester, _toggle);
      expect(_panel, findsNothing);
      _expectToggled(tester, false);

      semantics.dispose();
      await s.dispose(tester);
    });
  }

  testWidgets('a phone opens the details as a sheet over the call', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallDetailsShell(tester, width: 390, height: 844);
    expect(_toggle, findsNothing, reason: 'no tooltips on touch');

    await tester.tap(find.bySemanticsLabel('Call details'));
    await pumpFrames(tester, frames: 30);

    expect(_sheet, findsOneWidget);
    expect(_panel, findsNothing, reason: 'nothing docks at phone width');
    for (final section in ['This call', 'What happened', 'Transcript']) {
      expect(
        find.descendant(of: _sheet, matching: find.text(section)),
        findsOneWidget,
        reason: section,
      );
    }
    for (final edge in GeometryEdge.values) {
      expectClearOfEdge(tester, _sheet, edge, reason: '$edge');
    }
    expect(tester.getRect(_sheet).width, 390);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester, frames: 30);
    expect(_sheet, findsNothing);

    semantics.dispose();
    await s.dispose(tester);
  });

  testWidgets('the open panel shows a join as it lands', (tester) async {
    final s = await pumpCallDetailsShell(tester, width: 1280);
    await _tap(tester, _toggle);
    expect(_inPanel('Ann joined'), findsNothing);

    await s.join(tester, 'ann');

    expect(_inPanel('Ann joined'), findsOneWidget);
    await s.dispose(tester);
  });

  testWidgets('the chat and the details take turns in the one slot', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(tester, width: 1280);
    final chatOpen = s.container.read(voiceChatPaneVisibleProvider.notifier);
    await _tap(tester, _toggle);
    expect(_panel, findsOneWidget);

    await _tap(tester, find.byTooltip('Toggle text chat'));
    expect(chatOpen.state, isTrue);
    expect(_panel, findsNothing, reason: 'the chat took the slot');

    await _tap(tester, _toggle);
    expect(chatOpen.state, isFalse, reason: 'the details took it back');
    expect(_panel, findsOneWidget);
    await s.dispose(tester);
  });

  testWidgets('out of the call there is no toggle; the page shows the calls', (
    tester,
  ) async {
    final s = await pumpCallDetailsShell(
      tester,
      width: 1280,
      inCall: false,
      location: '/channels/$detailsVoiceId?details=1',
    );
    expect(_toggle, findsNothing);
    expect(find.text('This call'), findsOneWidget);
    expect(s.tokenRequests, isEmpty);
    await s.dispose(tester);
  });

  for (final width in [390.0, 700.0]) {
    testWidgets('where the details only sheet, the control is a plain button '
        'at $width', (tester) async {
      final semantics = tester.ensureSemantics();
      final s = await pumpCallDetailsShell(
        tester,
        width: width,
        height: width < 600 ? 844 : 900,
      );
      final control = find.bySemanticsLabel('Call details');
      expect(
        tester.getSemantics(control),
        isSemantics(hasToggledState: false, isButton: true),
      );

      await tester.tap(control);
      await pumpFrames(tester, frames: 30);
      expect(_sheet, findsOneWidget, reason: 'no room to dock at $width');

      semantics.dispose();
      await s.dispose(tester);
    });
  }
}
