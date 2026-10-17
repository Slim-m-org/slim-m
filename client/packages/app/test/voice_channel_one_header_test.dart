// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel with its text chat docked open used to stack two header
/// bars: the shell's slim voice header, then the docked `ChannelScreen`'s
/// full `ChannelHeader` - `showHeader: false` was passed and ignored - with
/// the canvas button in both. This pins the merged result: one header, every
/// action once.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_open_button.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_header.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart' show FixedVoiceController;

void main() {
  testWidgets(
    'a voice channel with chat open shows exactly one header, each action once',
    (tester) async {
      final s = setup(
        httpClient: quietClient(),
        signedIn: true,
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(
                state: VoiceSessionState.connected,
                channelId: 'c1',
              ),
            ),
          ),
        ],
      );
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'test-voice',
          kind: 'voice',
          createdAt: 0,
        ),
      ]);
      await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
      s.container.read(voiceChatPaneVisibleProvider.notifier).state = true;
      await tester.pumpAndSettle();

      expect(find.byType(ChannelScreen), findsOneWidget, reason: 'chat docked');
      expect(
        find.byType(ChannelHeader),
        findsOneWidget,
        reason: 'the docked pane must not add a second header bar',
      );
      expect(
        find.byType(CanvasOpenButton),
        findsOneWidget,
        reason: 'canvas appears once, not in both rows',
      );
      for (final label in [
        'Toggle text chat',
        'Search messages',
        'Toggle member list',
        'Pinned messages',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      expect(find.byIcon(AppIcons.hash), findsNothing, reason: 'chat, not #');
      expect(tester.takeException(), isNull);
      await teardown(tester, s.container, s.db);
    },
  );
}
