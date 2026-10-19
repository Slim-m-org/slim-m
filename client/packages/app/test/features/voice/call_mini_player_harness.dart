// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real shell with a call's mini-player on it, shared by the mini-player suites.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

const remoteShare = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);
const localShare = VoiceParticipant(
  identity: 'u-me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: true,
);
const remoteQuiet = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

VoiceState miniCall(List<VoiceParticipant> who) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  participants: who,
);

/// Disposing inside the test body is what stops the shell's debounces from
/// outliving the tree.
class MiniCtx {
  MiniCtx(this.tester, this.container, this.db, this.router);

  final WidgetTester tester;
  final ProviderContainer container;
  final SlimmDatabase db;
  final GoRouter router;

  Future<void> done() => teardownFixture(tester, container, db);
}

const phoneSize = Size(390, 844);
const desktopSize = Size(1400, 880);

Future<MiniCtx> pumpMini(
  WidgetTester tester, {
  required String location,
  required VoiceState voice,
  Size size = phoneSize,
  Brightness brightness = Brightness.dark,
}) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
    ],
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = fixtureRouter(location);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
          builder: appChromeBuilder,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return MiniCtx(tester, fixture.container, fixture.db, router);
}

Finder inPlayer(String label) => find.descendant(
  of: find.byKey(miniPlayerKey),
  matching: find.byTooltip(label),
);

/// An animated move starts on the frame after the change, so it needs two.
Future<void> settleMini(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}
