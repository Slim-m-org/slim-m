// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The lounge from the keyboard: Tab walks the tiles in reading order, the
/// menu key opens a tile's menu, Escape closes it and focus comes back.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

VoiceParticipant _p(String id, {bool local = false, bool camera = false}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isLocal: local,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
      isCameraOn: camera,
    );

Future<VoiceHarness> _connected(
  WidgetTester tester,
  List<VoiceParticipant> who,
) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants(who);
  await tester.pump();
  await tester.pumpAndSettle();
  return harness;
}

String? _focusedTile(WidgetTester tester) {
  final tile = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<CallParticipantTile>();
  return tile?.participant.identity;
}

void main() {
  testWidgets(
    'Tab visits tiles in reading order, the menu key opens, Escape closes',
    (tester) async {
      final harness = await _connected(tester, [
        _p('a', local: true),
        _p('b', camera: true),
        _p('c'),
      ]);
      addTearDown(harness.dispose);

      final order = <String>[];
      for (var i = 0; i < 40 && order.length < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final id = _focusedTile(tester);
        if (id != null && !order.contains(id)) order.add(id);
      }
      expect(order, ['a', 'b', 'c']);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.byType(AppMenuItem), findsWidgets);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppMenuItem), findsNothing);
      expect(_focusedTile(tester), 'c', reason: 'focus returns to the tile');

      await harness.container.read(voiceControllerProvider.notifier).leave();
    },
  );
}
