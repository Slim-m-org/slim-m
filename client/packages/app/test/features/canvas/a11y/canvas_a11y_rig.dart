// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared rig for the canvas accessibility probe: a real [CanvasPane] over a
/// connected call, pumped with semantics on at a chosen window size.
///
/// Not a `_test.dart` file, so `flutter test` does not run it. The reading
/// helpers (semantics rows, focus order, pixels, touch reach) live in
/// `canvas_a11y_probe.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../support/fake_blocks.dart';
import '../../voice/voice_controller_harness.dart';
import '../canvas_pane_harness.dart';

export '../canvas_pane_harness.dart'
    show canvasNoteJson, canvasObjectJson, screenFor, surfaceDocument;

const phoneSize = Size(390, 844);
const desktopSize = Size(1280, 800);

const meParticipant = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
  isCameraOn: true,
);

const priyaParticipant = VoiceParticipant(
  identity: 'user-priya',
  name: 'Priya',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const samSharingParticipant = VoiceParticipant(
  identity: 'user-sam',
  name: 'Sam',
  isSpeaking: false,
  isMuted: true,
  isLocal: false,
  isScreenSharing: true,
);

/// [testWidgets] with semantics on for the whole body, released even when it fails.
void a11yTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    // Reading pixels runs real async, which would otherwise hit the missing preferences plugin.
    SharedPreferences.setMockInitialValues({});
    final handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}

class A11yRig {
  A11yRig(this.tester, this.fixture, this.container, this.boundaryKey);

  final WidgetTester tester;
  final CanvasPaneFixture fixture;
  final ProviderContainer container;
  final GlobalKey boundaryKey;

  bool get memberPaneVisible => container.read(memberPaneVisibleProvider);
}

/// Pumps a [CanvasPane] on channel `c1`, semantics on, at a pixel ratio of one.
///
/// [call] joins a connected call with [participants]; [screenReader] sets the
/// platform's accessible-navigation flag, which the app treats like reduce motion.
Future<A11yRig> pumpA11yCanvas(
  WidgetTester tester, {
  Size size = desktopSize,
  bool call = true,
  List<VoiceParticipant> participants = const [
    meParticipant,
    priyaParticipant,
    samSharingParticipant,
  ],
  bool reduceMotion = false,
  bool screenReader = false,
  bool manage = true,
  List<Map<String, dynamic>> objects = const [],
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  int viewportStatus = 200,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final fixture = CanvasPaneFixture(
    mePermissions: manage ? Perm.manageCanvas : 0,
    viewportStatus: viewportStatus,
  )..objects = [...objects];
  addTearDown(fixture.events.close);
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(
          ref,
          call
              ? VoiceState(
                  channelId: 'c1',
                  state: VoiceSessionState.connected,
                  participants: participants,
                )
              : const VoiceState(),
        ),
      ),
      blocksProvider.overrideWith(
        (ref) => FixedBlocksController(ref, const BlocksState()),
      ),
    ],
  );
  addTearDown(container.dispose);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: boundaryKey,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            disableAnimations: reduceMotion,
            accessibleNavigation: screenReader,
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp(
            theme: buildTheme(
              brightness,
              brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
            ),
            home: const Scaffold(body: CanvasPane(channelId: 'c1')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return A11yRig(tester, fixture, container, boundaryKey);
}

/// Lets a route or menu transition run to its end; the first pump only starts its ticker.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// The tool the drawing surface is armed with right now.
CanvasTool currentTool(WidgetTester tester) =>
    tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool;

/// Frees the camera and the board so a test can address world coordinates directly.
void useFreeCamera(WidgetTester tester) {
  surfaceDocument(tester)
    ..setBoard(null)
    ..setCamera(const Camera());
}
