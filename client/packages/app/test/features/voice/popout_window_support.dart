// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared rig for the pop-out window tests: a fake window handle and a pumped main window.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/desktop/popout/popout_windowing.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart' show ResizeEdge;
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/popout_window.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

class FakePopOutWindow implements PopOutWindowHandle {
  FakePopOutWindow(
    this.onCloseRequested, {
    required this.decorated,
    required this.title,
  });

  final VoidCallback onCloseRequested;
  final bool decorated;
  final String title;
  bool destroyed = false;
  int keptAbove = 0;

  @override
  Future<void> keepAbove() async => keptAbove++;

  @override
  bool get drawsOwnFrame => !decorated;
  int moves = 0;
  final resizes = <ResizeEdge>[];

  @override
  void beginMove() => moves++;

  @override
  void beginResize(ResizeEdge edge) => resizes.add(edge);

  @override
  void fitAspect(double aspect) {}

  @override
  Widget host(Widget child) => const ViewCollection(views: []);

  @override
  void destroy() => destroyed = true;
}

const adaSharing = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);
const adaStopped = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const boSharing = VoiceParticipant(
  identity: 'u-bo',
  name: 'Bo',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

MiniPlayerFeed screenFeed(VoiceParticipant p) =>
    (identity: p.identity, name: p.name, kind: FeedKind.screenShare);

VoiceState callOf(List<VoiceParticipant> who) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  participants: who,
);

class PopOutRig {
  final session = FakeSession();
  final windows = <FakePopOutWindow>[];
  final openedInPhase = <SchedulerPhase>[];
  late final ProviderContainer container;
  late final SlimmDatabase db;
  FixedVoiceController get voice =>
      container.read(voiceControllerProvider.notifier) as FixedVoiceController;
}

Future<PopOutRig> pumpPopOut(
  WidgetTester tester, {
  required bool supported,
  List<VoiceParticipant> who = const [adaSharing],
  PopOutWindowFactory? factory,
}) async {
  final rig = PopOutRig();
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, callOf(who), rig.session),
      ),
      popOutWindowFactoryProvider.overrideWithValue(
        factory ??
            (supported
                ? ({
                    required title,
                    required size,
                    required decorated,
                    required onCloseRequested,
                  }) {
                    final w = FakePopOutWindow(
                      onCloseRequested,
                      decorated: decorated,
                      title: title,
                    );
                    rig.windows.add(w);
                    rig.openedInPhase.add(
                      SchedulerBinding.instance.schedulerPhase,
                    );
                    return w;
                  }
                : null),
      ),
    ],
  );
  rig.container = fixture.container;
  rig.db = fixture.db;
  tester.view.physicalSize = const Size(1400, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
        builder: appChromeBuilder,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return rig;
}

Finder get popOutButton => find.descendant(
  of: find.byKey(miniPlayerKey),
  matching: find.byTooltip('Pop out'),
);
