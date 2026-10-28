// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas inside the real [HomeShell] with the member pane docked and a call connected: whether Escape reaches the right widget and where focus goes when the canvas closes.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../settings/home_shell_harness.dart';
import '../../voice/voice_controller_harness.dart';
import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

/// A voice channel with a connected call and its canvas already open, at a
/// width that docks the rail and the member pane.
Future<ShellScene> _openCanvasInShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(
          ref,
          const VoiceState(
            channelId: 'c1',
            state: VoiceSessionState.connected,
            participants: [meParticipant, priyaParticipant],
          ),
        ),
      ),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'voice', createdAt: 0),
  ]);
  s.container.read(canvasOpenProvider.notifier).state = 'c1';
  await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
  await tester.pump(const Duration(seconds: 1));
  return s;
}

typedef ShellScene = ({ProviderContainer container, SlimmDatabase db});

void main() {
  a11yTest('Escape closes the overflow menu beside the real member pane', (
    tester,
  ) async {
    final s = await _openCanvasInShell(tester);
    await openOverflowByKeyboard(tester);
    expect(find.text('Paste image'), findsOneWidget);

    await pressKey(tester, LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('Paste image'), findsNothing);
    await teardown(tester, s.container, s.db);
  });

  a11yTest('Escape in the overflow menu leaves the real member pane open', (
    tester,
  ) async {
    final s = await _openCanvasInShell(tester);
    expect(find.byType(AppMemberPane), findsOneWidget);
    await openOverflowByKeyboard(tester);

    await pressKey(tester, LogicalKeyboardKey.escape);
    await settle(tester);

    expect(
      find.byType(AppMemberPane),
      findsOneWidget,
      reason: 'Escape meant for the menu closed the member pane',
    );
    await teardown(tester, s.container, s.db);
  });

  a11yTest('closing the canvas from the keyboard puts focus on Open canvas', (
    tester,
  ) async {
    final s = await _openCanvasInShell(tester);
    expect(await tabTo(tester, 'Close canvas'), isTrue);

    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    expect(s.container.read(canvasOpenProvider), isNull);
    expect(
      focusedName(tester),
      contains('Open canvas'),
      reason:
          'the button that took the Close slot is where focus belongs; '
          'instead the next Tab starts again from the top of the screen',
    );
    await teardown(tester, s.container, s.db);
  });

  a11yTest('the Participants sheet takes keyboard focus in the real shell', (
    tester,
  ) async {
    final s = await _openCanvasInShell(tester);
    await runOverflowItem(tester, 'People here');
    expect(find.text('People here'), findsOneWidget);

    expect(
      focusIsInModal(),
      isTrue,
      reason: 'focus is on "${focusedName(tester)}" behind the sheet',
    );
    await teardown(tester, s.container, s.db);
  });

  a11yTest('Escape closes the Participants sheet in the real shell', (
    tester,
  ) async {
    final s = await _openCanvasInShell(tester);
    await runOverflowItem(tester, 'People here');

    await pressKey(tester, LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('People here'), findsNothing);
    await teardown(tester, s.container, s.db);
  });
}
