// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0086: everyone in the call is overlapping avatars at the canvas corner that open a list, each row opening the menu a call tile has.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_roster_avatar.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_roster_cluster.dart';
import 'package:slimm_app/src/features/members/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_health.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/voice_controller_harness.dart';

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
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      channelBotUiProvider.overrideWith((ref, _) async => const []),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
      voiceParticipantsProvider.overrideWithValue(participants),
      if (poor.isNotEmpty)
        poorConnectionsProvider.overrideWith(
          (ref) => ListenableState(ValueNotifier(poor)),
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CanvasRosterCluster(),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _row(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(AppListRow)).first;

Future<void> _openList(WidgetTester tester) async {
  await tester.tap(find.byTooltip('People in this call'));
  // A speaking ring never settles.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('alone in the call there is nothing to list', (tester) async {
    await _pump(tester, [_person('me', local: true)]);

    expect(find.byType(CanvasRosterAvatar), findsNothing);
  });

  testWidgets('the pill overlaps the first three, the rest fold into +n', (
    tester,
  ) async {
    await _pump(tester, [
      _person('me', local: true),
      for (var i = 0; i < 5; i++) _person('p$i'),
    ]);

    expect(find.byType(CanvasRosterAvatar), findsNWidgets(3));
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('a speaker is never folded away', (tester) async {
    await _pump(tester, [
      _person('me', local: true),
      for (var i = 0; i < 5; i++) _person('p$i', speaking: i == 4),
    ]);

    final shown = tester
        .widgetList<CanvasRosterAvatar>(find.byType(CanvasRosterAvatar))
        .map((a) => a.participant.identity);
    expect(shown, contains('p4'));
  });

  testWidgets('clicking the pill lists everyone with their name', (
    tester,
  ) async {
    await _pump(tester, [
      _person('me', local: true),
      _person('bob', speaking: true),
      _person('cy', muted: true),
    ]);

    await _openList(tester);

    expect(_row('BOB'), findsOneWidget);
    expect(_row('CY'), findsOneWidget);
    expect(_row('ME'), findsOneWidget);
    expect(find.byIcon(AppIcons.micOff), findsNWidgets(2));
  });

  testWidgets('clicking outside closes the list', (tester) async {
    await _pump(tester, [_person('me', local: true), _person('bob')]);
    await _openList(tester);

    await tester.tapAt(const Offset(600, 600));
    await tester.pumpAndSettle();

    expect(find.text('In this call'), findsNothing);
  });

  testWidgets('right-clicking a row opens the same menu a call tile has', (
    tester,
  ) async {
    await _pump(tester, [_person('me', local: true), _person('bob')]);
    await _openList(tester);

    await tester.tap(_row('BOB'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('Mute for me'), findsOneWidget);
  });

  testWidgets('a long press on a row opens it on a phone', (tester) async {
    await _pump(tester, [
      _person('me', local: true),
      _person('bob'),
    ], width: 390);
    await _openList(tester);

    await tester.longPress(_row('BOB'));
    await tester.pumpAndSettle();

    expect(find.text('Mute for me'), findsOneWidget);
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
    await _openList(tester);
    expect(find.byKey(poorConnectionBadgeKey), findsNWidgets(2));
    semantics.dispose();
  });
}
