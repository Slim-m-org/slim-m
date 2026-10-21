// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's call controls follow the call into the wide canvas dock. They used
/// to live only in the voice screen's dock, so opening the canvas hid them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/bot_call_controls.dart';
import 'package:slimm_app/src/widgets/hover_reveal.dart';
import 'package:slimm_design_system/design_system.dart';
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
  bool compact = false,
  double width = 800,
}) async {
  final dock = await pumpCanvasCallDock(
    tester,
    withCall: true,
    canvas: buildCanvasDockData(),
    width: width,
    compact: compact,
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

  group('on a phone-width canvas', () {
    Future<VoiceController> pumpPhone(
      WidgetTester tester, {
      required bool botOnCall,
    }) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return _pumpWithBot(
        tester,
        botOnCall: botOnCall,
        compact: true,
        width: 360,
      );
    }

    testWidgets('one chip per bot opens its controls in a sheet', (
      tester,
    ) async {
      final call = await pumpPhone(tester, botOnCall: true);

      expect(find.byType(BotCallControls), findsNothing);
      expect(find.byTooltip('Jellyfin controls'), findsNothing);
      await tester.longPress(find.bySemanticsLabel(RegExp('^Mute')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jellyfin controls'));
      await tester.pumpAndSettle();

      expect(find.byType(BotCallControls), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(BotCallControls))).pop();
      await tester.pumpAndSettle();
      await _leave(tester, call);
    });

    testWidgets('no chip without the bot on the call', (tester) async {
      final call = await pumpPhone(tester, botOnCall: false);

      expect(find.byTooltip('Jellyfin controls'), findsNothing);
      await _leave(tester, call);
    });

    testWidgets('the menu row is a 44dp target inside the screen', (
      tester,
    ) async {
      final call = await pumpPhone(tester, botOnCall: true);

      await tester.longPress(find.bySemanticsLabel(RegExp('^Mute')));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('Jellyfin controls'));
      expect(rect.height, greaterThanOrEqualTo(20));
      expect(
        (Offset.zero & const Size(360, 640)).contains(rect.bottomRight),
        isTrue,
      );
      await _leave(tester, call);
    });
  });

  testWidgets('a bot control\'s option menu holds a collapsed dock open', (
    tester,
  ) async {
    const group = BotCallGroup(
      bot: _jellyfin,
      controls: [
        api.BotUiEntry(
          id: 'volume',
          label: 'Volume',
          icon: 'volume',
          options: [api.BotUiOption(id: 'up', label: 'Louder')],
        ),
      ],
    );
    final pins = <bool>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: HoverRevealScope(
              pin: pins.add,
              reportMenuOpen: (_) {},
              reportOverlayHover: (_) {},
              child: const Align(
                alignment: Alignment.bottomCenter,
                child: BotCallControls(channelId: 'c1', groups: [group]),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Volume'));
    await tester.pumpAndSettle();
    expect(pins, [true]);

    await tester.tap(find.text('Louder'));
    await tester.pumpAndSettle();
    expect(pins, [true, false]);
  });
}
