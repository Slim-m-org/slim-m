// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's rows in a message menu, and its controls in a call's dock, at phone
/// and desktop width in both themes. The PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts both lay out without overflow.
/// See docs/decisions/0045-bot-contributed-ui.md.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/screens/voice_call_dock.dart';
import 'package:slimm_app/src/widgets/bot_call_controls.dart';
import 'package:slimm_app/src/widgets/bot_menu_sections.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'message_row_harness.dart';
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';
import 'voice_call_controls_harness.dart' show InertSession;

const _bots = [
  api.ChannelBotUi(
    botUserId: 'jelly',
    botUsername: 'jellyfin',
    botDisplayName: 'Jellyfin',
    messageMenu: [
      api.BotUiEntry(id: 'queue', label: 'Queue this'),
      api.BotUiEntry(id: 'watch', label: 'Add to watch party'),
    ],
    callControls: [
      api.BotUiEntry(id: 'prev', label: 'Previous', icon: 'skip_previous'),
      api.BotUiEntry(id: 'pause', label: 'Pause', icon: 'pause'),
      api.BotUiEntry(id: 'skip', label: 'Skip', icon: 'skip_next'),
      api.BotUiEntry(id: 'stop', label: 'Stop', icon: 'stop'),
      api.BotUiEntry(
        id: 'quality',
        label: 'Quality',
        icon: 'settings',
        options: [
          api.BotUiOption(id: 'low', label: 'Low 480p'),
          api.BotUiOption(id: 'medium', label: 'Medium 720p'),
          api.BotUiOption(id: 'high', label: 'High 1080p'),
        ],
      ),
    ],
  ),
  api.ChannelBotUi(
    botUserId: 'mods',
    botUsername: 'modbot',
    botDisplayName: 'Mod helper',
    messageMenu: [api.BotUiEntry(id: 'report', label: 'Report to mods bot')],
    callControls: [],
  ),
];

MessageActions _actions() {
  final sections = botMenuSections(_bots, onUse: (_, _) {});
  return MessageActions(
    canReply: true,
    onReply: noop,
    canEdit: false,
    onEdit: noop,
    canDelete: true,
    onDelete: noop,
    canManagePins: false,
    pinned: false,
    onTogglePin: noop,
    canReport: true,
    onReport: noop,
    canBlockAuthor: true,
    onBlockAuthor: noop,
    canOpenThread: false,
    onOpenThread: noop,
    canCopyLink: false,
    onCopyLink: noop,
    canForward: true,
    onForward: noop,
    canSave: true,
    onSave: noop,
    botSections: sections,
  );
}

ThemeData _theme(bool dark) => dark
    ? buildTheme(Brightness.dark, AppTokens.dark)
    : buildTheme(Brightness.light, AppTokens.light);

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'phone': Size(390, 844), 'desktop': Size(1400, 880)};
  for (final dark in const [true, false]) {
    final mode = dark ? 'dark' : 'light';
    for (final entry in sizes.entries) {
      final name = 'bot-message-menu-${entry.key}-$mode';
      testWidgets('message menu with a bot section at ${entry.key} ($mode)', (
        tester,
      ) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: _theme(dark),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: MessageRow(
                      message: message(content: 'guten tag, wie geht es dir'),
                      grouped: false,
                      showNewDivider: false,
                      knownUsernames: const {},
                      actions: _actions(),
                      editing: false,
                      callbacks: MessageRowCallbacks(
                        onRetry: () {},
                        onDiscard: () {},
                        onPickReaction: (_) {},
                        onReactionTap: (_) {},
                        onVote: (_) {},
                        onSubmitEdit: (_) {},
                        onCancelEdit: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final press =
            tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
            const Offset(30, 30);
        if (entry.key == 'phone') {
          await tester.longPressAt(press);
        } else {
          await tester.tapAt(press, buttons: kSecondaryButton);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('Queue this'), findsOneWidget);
        expect(find.text('Report to mods bot'), findsOneWidget);
        await expectSettled(tester, name);
        await writeSnapshot(tester, name);
        expect(tester.takeException(), isNull);
      });

      final dockName = 'bot-call-controls-${entry.key}-$mode';
      testWidgets('call dock with bot controls at ${entry.key} ($mode)', (
        tester,
      ) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: InertSession()),
            ),
          ],
        );
        addTearDown(container.dispose);
        final touch = entry.key == 'phone';
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: _theme(dark),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(
                      minimum: const EdgeInsets.all(AppSpacing.s12),
                      child: AppTouchTargets(
                        enabled: touch,
                        child: VoiceCallDock(
                          controller: container.read(
                            voiceControllerProvider.notifier,
                          ),
                          voice: const VoiceFlags(
                            channelId: 'c1',
                            state: VoiceSessionState.connected,
                          ),
                          canvasChannelId: 'c1',
                          botControls: BotCallControls(
                            channelId: 'c1',
                            groups: botCallGroups(_bots, {'me', 'jelly'}),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Jellyfin'), findsOneWidget);
        expect(find.text('Mod helper'), findsNothing);
        await expectSettled(tester, dockName);
        await writeSnapshot(tester, dockName);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Quality'));
        await tester.pumpAndSettle();
        expect(find.text('Medium 720p'), findsOneWidget);
        await expectSettled(tester, '$dockName-options');
        await writeSnapshot(tester, '$dockName-options');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
