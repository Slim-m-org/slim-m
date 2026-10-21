// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0086: the dock lists everyone in the call as avatars, with a
/// speaking ring and a muted badge, and each opens the participant menu a call
/// tile has.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_call_roster.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_participants_sheet.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';

VoiceParticipant _person(
  String id, {
  bool local = false,
  bool speaking = false,
  bool muted = false,
}) => VoiceParticipant(
  identity: id,
  name: id.toUpperCase(),
  isSpeaking: speaking,
  isMuted: muted,
  isLocal: local,
  isScreenSharing: false,
);

Future<void> _pump(
  WidgetTester tester,
  List<VoiceParticipant> participants, {
  double width = 800,
  Set<String> poor = const {},
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasCallDock(
    tester,
    withCall: true,
    canvas: buildCanvasDockData(),
    participants: participants,
    width: width,
    poorConnections: poor,
  );
}

void main() {
  testWidgets('alone in the call there is no roster to list', (tester) async {
    await _pump(tester, [_person('me', local: true)]);

    expect(find.byType(CanvasCallRoster), findsNothing);
  });

  testWidgets('everyone in the call is an avatar, the speaker ringed', (
    tester,
  ) async {
    await _pump(tester, [
      _person('me', local: true),
      _person('bob', speaking: true),
      _person('cy'),
    ]);

    final avatars = tester
        .widgetList<UserAvatar>(
          find.descendant(
            of: find.byType(CanvasCallRoster),
            matching: find.byType(UserAvatar),
          ),
        )
        .toList();
    expect(avatars.map((a) => a.name), ['ME', 'BOB', 'CY']);
    expect(avatars.map((a) => a.speaking), [false, true, false]);
  });

  testWidgets('a muted person carries the muted badge', (tester) async {
    await _pump(tester, [
      _person('me', local: true),
      _person('bob', muted: true),
    ]);

    expect(
      find.descendant(
        of: find.byType(CanvasCallRoster),
        matching: find.byIcon(AppIcons.micOff),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a person opens the call tile menu for them', (
    tester,
  ) async {
    await _pump(tester, [_person('me', local: true), _person('bob')]);

    await tester.tap(find.byTooltip('BOB'));
    await tester.pumpAndSettle();

    expect(find.text('Mute for me'), findsOneWidget);
  });

  testWidgets('right-clicking a person opens the same menu', (tester) async {
    await _pump(tester, [_person('me', local: true), _person('bob')]);

    await tester.tap(find.byTooltip('BOB'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('Mute for me'), findsOneWidget);
  });

  testWidgets('a crowd folds into +n, which opens the full list', (
    tester,
  ) async {
    final crowd = [
      _person('me', local: true),
      for (var i = 0; i < 12; i++) _person('p$i'),
    ];
    await _pump(tester, crowd);

    final shown = canvasRosterCapacity(800);
    expect(find.text('+${crowd.length - shown}'), findsOneWidget);

    await tester.tap(find.text('+${crowd.length - shown}'));
    await tester.pumpAndSettle();

    expect(find.byType(CanvasParticipantsSheet), findsOneWidget);
  });

  testWidgets('a poor connection marks that person, and only them', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      [_person('me', local: true), _person('bob')],
      poor: {'bob'},
    );

    expect(find.byKey(poorConnectionBadgeKey), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('BOB.*connection is unstable')),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
