// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop pop-out: what offers it, what opens and closes the window, and
/// that the window's controls act on the same call the main window holds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/desktop/popout/popout_windowing.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart' show ResizeEdge;
import 'package:slimm_app/src/providers/call_mini_player.dart';
import 'package:slimm_app/src/providers/popout_window.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/call_mini_player.dart';
import 'package:slimm_app/src/widgets/popout_window_view.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

class _Controller extends VoiceController {
  _Controller(super.ref, VoiceState initial, FakeSession session)
    : super(session: session) {
    state = initial;
  }

  void replace(VoiceState next) => state = next;
}

class _FakeWindow implements PopOutWindowHandle {
  _FakeWindow(this.onCloseRequested, {required this.decorated});

  final VoidCallback onCloseRequested;
  final bool decorated;
  bool destroyed = false;
  int moves = 0;
  final resizes = <ResizeEdge>[];

  @override
  void beginMove() => moves++;

  @override
  void beginResize(ResizeEdge edge) => resizes.add(edge);

  @override
  Widget host(Widget child) => const ViewCollection(views: []);

  @override
  void destroy() => destroyed = true;
}

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);
const _adaStopped = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

VoiceState _call(List<VoiceParticipant> who) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  participants: who,
);

class _Rig {
  final session = FakeSession();
  final windows = <_FakeWindow>[];
  late final ProviderContainer container;
  late final SlimmDatabase db;
  _Controller get voice =>
      container.read(voiceControllerProvider.notifier) as _Controller;
}

Future<_Rig> _pump(WidgetTester tester, {required bool supported}) async {
  final rig = _Rig();
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => _Controller(ref, _call([_ada]), rig.session),
      ),
      popOutWindowFactoryProvider.overrideWithValue(
        supported
            ? ({
                required title,
                required size,
                required decorated,
                required onCloseRequested,
              }) {
                final w = _FakeWindow(onCloseRequested, decorated: decorated);
                rig.windows.add(w);
                return w;
              }
            : null,
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

Finder get _popOutButton => find.descendant(
  of: find.byKey(miniPlayerKey),
  matching: find.byTooltip('Pop out'),
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('no pop-out control where windowing is unavailable', (
    tester,
  ) async {
    final rig = await _pump(tester, supported: false);
    expect(find.byKey(miniPlayerKey), findsOneWidget);
    expect(_popOutButton, findsNothing);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('pop out opens a window; closing it keeps the call', (
    tester,
  ) async {
    final rig = await _pump(tester, supported: true);
    await tester.tap(_popOutButton);
    await tester.pump();
    expect(rig.windows, hasLength(1));
    expect(rig.container.read(popOutFeedProvider)?.identity, 'u-ada');

    rig.windows.single.onCloseRequested();
    await tester.pump();
    expect(rig.windows.single.destroyed, isTrue);
    expect(rig.container.read(popOutFeedProvider), isNull);
    expect(rig.session.leaveCalls, 0);
    expect(rig.voice.state.state, VoiceSessionState.connected);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window is requested without OS decorations', (tester) async {
    final rig = await _pump(tester, supported: true);
    await tester.tap(_popOutButton);
    await tester.pump();
    expect(rig.windows.single.decorated, isFalse);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window closes when the share stops', (tester) async {
    final rig = await _pump(tester, supported: true);
    await tester.tap(_popOutButton);
    await tester.pump();
    rig.voice.replace(_call([_adaStopped]));
    await tester.pump();
    expect(rig.windows.single.destroyed, isTrue);
    expect(rig.container.read(popOutFeedProvider), isNull);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window closes when the call ends', (tester) async {
    final rig = await _pump(tester, supported: true);
    await tester.tap(_popOutButton);
    await tester.pump();
    rig.voice.replace(const VoiceState());
    await tester.pump();
    expect(rig.windows.single.destroyed, isTrue);
    await teardownFixture(tester, rig.container, rig.db);
  });

  group('window content', () {
    var moves = 0;
    var closes = 0;
    final resizes = <ResizeEdge>[];
    final frame = PopOutFrame(
      onMoveStart: () => moves++,
      onResizeStart: resizes.add,
      onClose: () => closes++,
    );

    Future<_Rig> content(
      WidgetTester tester,
      double width, {
      PopOutFrame? frame,
    }) async {
      final rig = _Rig();
      final fixture = await fixtureContainer(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => _Controller(ref, _call([_ada]), rig.session),
          ),
        ],
      );
      rig.container = fixture.container;
      rig.db = fixture.db;
      tester.view.physicalSize = Size(width, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: PopOutWindowView(
              feed: (
                identity: 'u-ada',
                name: 'Ada',
                kind: FeedKind.screenShare,
              ),
              frame: frame,
            ),
          ),
        ),
      );
      await tester.pump();
      return rig;
    }

    testWidgets('borderless frame: drag, resize edges and close', (
      tester,
    ) async {
      final rig = await content(tester, 640, frame: frame);
      await tester.startGesture(
        tester.getCenter(find.byKey(popOutDragRegionKey)),
      );
      expect(moves, 1);
      expect(find.byTooltip('Close pop-out'), findsOneWidget);
      await tester.tap(find.byTooltip('Close pop-out'));
      expect(closes, 1);
      final corner = tester.getBottomRight(find.byKey(popOutWindowKey));
      await tester.dragFrom(
        corner - const Offset(2, 2),
        const Offset(-20, -20),
      );
      expect(resizes, [ResizeEdge.bottomRight]);
      expect(rig.session.leaveCalls, 0);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('a decorated window draws no frame of its own', (tester) async {
      final rig = await content(tester, 640);
      expect(find.byKey(popOutDragRegionKey), findsNothing);
      expect(find.byTooltip('Close pop-out'), findsNothing);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('mute and leave act on the shared call', (tester) async {
      final rig = await content(tester, 640);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(rig.voice.state.microphoneEnabled, isFalse);
      await tester.tap(find.byTooltip('Leave call'));
      await tester.pump();
      expect(rig.session.leaveCalls, 1);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('control density follows the window width', (tester) async {
      final wide = await content(tester, 900);
      final pointer = tester.getSize(find.byTooltip('Mute')).height;
      await teardownFixture(tester, wide.container, wide.db);
      final narrow = await content(tester, 320);
      final touch = tester.getSize(find.byTooltip('Mute')).height;
      expect(pointer, AppSizes.rowPointer);
      expect(touch, AppSizes.rowTouch);
      await teardownFixture(tester, narrow.container, narrow.db);
    });
  });
}
