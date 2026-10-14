// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice connecting loader: the status names the real phase, Cancel
/// leaves, the room end shows who is already in the call, and the loader
/// renders in both themes at desktop and phone width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/voice_join_preview.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_app/src/widgets/voice_connecting_loader.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

class _Me extends EffectiveMe {
  @override
  api.Me? build() => const api.Me(
    id: 'me',
    username: 'mara',
    displayName: 'Mara Lindqvist',
    createdAt: 0,
    permissions: 0,
  );
}

const _room = [
  api.VoiceRosterParticipant(
    userId: 'k',
    displayName: 'kiki',
    isSharingScreen: false,
    hasVideo: false,
  ),
  api.VoiceRosterParticipant(
    userId: 'j',
    displayName: 'Jonas Berg',
    isSharingScreen: false,
    hasVideo: false,
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  bool negotiating = false,
  List<api.VoiceRosterParticipant> room = _room,
  VoidCallback? onCancel,
  String theme = 'dark',
  Size size = const Size(720, 420),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tokens = theme == 'dark' ? AppTokens.dark : AppTokens.light;
  await tester.pumpWidget(
    RepaintBoundary(
      key: snapshotBoundary,
      child: ProviderScope(
        overrides: [
          effectiveMeProvider.overrideWith(_Me.new),
          voiceRosterProvider.overrideWith((ref, _) => Stream.value(room)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            theme == 'dark' ? Brightness.dark : Brightness.light,
            tokens,
          ),
          home: Scaffold(
            backgroundColor: tokens.surfaceBase,
            body: VoiceConnecting(
              channelId: 'lounge',
              negotiating: negotiating,
              onCancel: onCancel ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the status names the phase the join is in', (tester) async {
    await _pump(tester);
    expect(find.text('Connecting'), findsOneWidget);

    await _pump(tester, negotiating: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Negotiating audio'), findsOneWidget);
    expect(find.text('Connecting'), findsNothing);
  });

  testWidgets('Cancel leaves the join', (tester) async {
    var cancelled = 0;
    await _pump(tester, onCancel: () => cancelled++);
    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);
  });

  testWidgets('the lane runs from you to the people already in the call', (
    tester,
  ) async {
    await _pump(tester);
    final names = tester
        .widgetList<UserAvatar>(find.byType(UserAvatar))
        .map((a) => a.name)
        .toList();
    expect(names, ['Mara Lindqvist', 'kiki', 'Jonas Berg']);
    final lane = tester.getRect(find.byType(VoiceConnectingLoader));
    final me = tester.getRect(find.byType(UserAvatar).first);
    expect(me.left, lane.left, reason: 'you sit at the start of the lane');
  });

  for (final (name, negotiating, theme, size) in [
    ('voice-connecting-reaching', false, 'dark', const Size(720, 420)),
    ('voice-connecting-negotiating', true, 'light', const Size(720, 420)),
    ('voice-connecting-phone', false, 'dark', const Size(390, 600)),
  ]) {
    testWidgets('$name fits its viewport', (tester) async {
      await _pump(tester, theme: theme, size: size);
      if (negotiating) {
        await _pump(tester, negotiating: true, theme: theme, size: size);
        await tester.pump(const Duration(milliseconds: 500));
      }
      await writeSnapshot(tester, name);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an empty room still gives the lane somewhere to run', (
    tester,
  ) async {
    await _pump(tester, room: const []);
    expect(find.byType(UserAvatar), findsOneWidget);
    await writeSnapshot(tester, 'voice-connecting-empty-room');
  });
}
