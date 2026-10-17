// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's call controls follow the call into the wide canvas dock. They used
/// to live only in the voice screen's dock, so opening the canvas hid them.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/bot_call_controls.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';

const _jellyfin = api.ChannelBotUi(
  botUserId: 'jelly',
  botUsername: 'jellyfin',
  botDisplayName: 'Jellyfin',
  messageMenu: [],
  callControls: [api.BotUiEntry(id: 'pause', label: 'Pause', icon: 'pause')],
);

const _jellyOnCall = VoiceParticipant(
  identity: 'jelly',
  name: 'Jellyfin',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

Future<VoiceController> _pumpWithBot(
  WidgetTester tester, {
  required bool botOnCall,
}) async {
  final dock = await pumpCanvasCallDock(
    tester,
    withCall: true,
    canvas: buildCanvasDockData(),
    width: 800,
    bots: const [_jellyfin],
  );
  await dock.controller!.join('c1');
  dock.session!.emitState(VoiceSessionState.connected);
  dock.session!.emitParticipants(botOnCall ? const [_jellyOnCall] : const []);
  await tester.pumpAndSettle();
  return dock.controller!;
}

Future<void> _leave(WidgetTester tester, VoiceController controller) async {
  await controller.leave();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the canvas dock shows a bot on the call its controls', (
    tester,
  ) async {
    final call = await _pumpWithBot(tester, botOnCall: true);

    expect(find.byType(BotCallControls), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    await _leave(tester, call);
  });

  testWidgets('the canvas dock drops them once the bot leaves', (tester) async {
    final call = await _pumpWithBot(tester, botOnCall: false);

    expect(find.byType(BotCallControls), findsNothing);
    await _leave(tester, call);
  });
}
